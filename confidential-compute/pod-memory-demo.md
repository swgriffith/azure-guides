# Confidential Compute Demo

In this walkthrough we'll demonstrate the risk of priviledged memory access and how Azure Confidential Containers on AKS can mitigate this risk.

## Feature Registration

This example relies on enabling the Kata Confidential Containers feature, which is currently in preview as well as enabling the aks-preview and confcom Azure CLI extensions.

```bash
# Add or update the aks-preview cli extension
az extension add --name aks-preview
# or if you already have aks-preview installed
az extension update --name aks-preview

# Add or update the confcom cli extension
az extension add --name confcom
# of i you already have confcom installed
az extension update --name confcom

# Register for the Kata CC preview feature
az feature register --namespace "Microsoft.ContainerService" --name "KataCcIsolationPreview"
# To check status on the preview registration
az feature show --namespace "Microsoft.ContainerService" --name "KataCcIsolationPreview"

# Once registration completes you need to re-register the Microsoft.ContainerService provider
az provider register --namespace "Microsoft.ContainerService"
```

## Cluster Creation

Now lets create the AKS cluster with the OIDC Issure and Workload Identity add-on enabled, using AMD nodes supporting SEV-SNP.

```bash
export RG=ConfidentialContainers
export LOC=eastus
export CLUSTER_NAME=wilab
export UNIQUE_ID=$CLUSTER_NAME$RANDOM
export ACR_NAME=$UNIQUE_ID
export KEY_VAULT_NAME=$UNIQUE_ID

# Create the resource group
az group create -g $RG -l $LOC

# Create the cluster with the OIDC Issuer and Workload Identity enabled
az aks create -g $RG -n $CLUSTER_NAME \
--node-count 1 \
--enable-oidc-issuer \
--enable-workload-identity \
--generate-ssh-keys

az aks nodepool add \
--resource-group $RG \
--name kataccpool \
--cluster-name $CLUSTER_NAME \
--node-count 1 \
--os-sku AzureLinux \
--node-vm-size Standard_DC4as_cc_v5 \
--workload-runtime KataCcIsolation

# Get the cluster credentials
az aks get-credentials -g $RG -n $CLUSTER_NAME
```

### Set up the identity 

In order to federate a managed identity with a Kubernetes Service Account we need to get the AKS OIDC Issure URL, create the Managed Identity and Service Account and then create the federation.

```bash
# Get the OIDC Issuer URL
export AKS_OIDC_ISSUER="$(az aks show -n $CLUSTER_NAME -g $RG --query "oidcIssuerProfile.issuerUrl" -otsv)"

# Create the managed identity
az identity create --name wi-demo-identity --resource-group $RG --location $LOC

# Get identity client ID
export USER_ASSIGNED_CLIENT_ID=$(az identity show --resource-group $RG --name wi-demo-identity --query 'clientId' -o tsv)

# Create a service account to federate with the managed identity
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  annotations:
    azure.workload.identity/client-id: ${USER_ASSIGNED_CLIENT_ID}
  labels:
    azure.workload.identity/use: "true"
  name: wi-demo-sa
  namespace: default
EOF

# Federate the identity
az identity federated-credential create \
--name wi-demo-federated-id \
--identity-name wi-demo-identity \
--resource-group $RG \
--issuer ${AKS_OIDC_ISSUER} \
--subject system:serviceaccount:default:wi-demo-sa
```

### Create the Key Vault and Secret

The sample app will pull a value from Key Vault, in the same way you might pull a database connection string or other secret for use at runtime, so we'll need to create the Azure Key Vault instance an store the secret.

```bash
# Create a key vault
az keyvault create --name $KEY_VAULT_NAME --resource-group $RG --location $LOC

USER_ID=$(az ad signed-in-user show --query id -o tsv)
az keyvault set-policy -n $KEY_VAULT_NAME --resource-group $RG --certificate-permissions get --object-id $USER_ID

# Create a secret
az keyvault secret set --vault-name $KEY_VAULT_NAME --name "Secret" --value "Drink More Ovaltine"

# Grant access to the secret for the managed identity
az keyvault set-policy --name $KEY_VAULT_NAME --resource-group $RG --secret-permissions get --spn "${USER_ASSIGNED_CLIENT_ID}"
```

### Create the sample python app

Now we'll create a python app that uses the azure identity and key vault SDKs to pull the secret value.

```bash
# Create a new directory for the application
mkdir wi-python
cd wi-python

# Install the needed packages
pip install azure-identity
pip install azure-keyvault-secrets
```

Create a new file called kv_secrets.py with the following:

```python
import os
import ctypes
import time
from azure.keyvault.secrets import SecretClient
from azure.identity import DefaultAzureCredential

keyVaultName = os.environ["KEY_VAULT_NAME"]
secretName = os.environ["SECRET_NAME"]
KVUri = f"https://{keyVaultName}.vault.azure.net"

credential = DefaultAzureCredential()
client = SecretClient(vault_url=KVUri, credential=credential)

while True:
    print(f"Retrieving your secret from {keyVaultName}.")
    retrieved_secret = client.get_secret(secretName).value
    memAddr=id(retrieved_secret)
    print(f"Secret Memory Address: {memAddr}")
    print(f"Secret value: {retrieved_secret}")
    time.sleep(600)
```

Create a new Dockerfile with the following:

```bash
FROM python:3.7

ENV PYTHONUNBUFFERED=1

RUN mkdir /app
WORKDIR /app
ADD kv_secrets.py /app/
RUN pip install azure-identity azure-keyvault-secrets

CMD ["python", "/app/kv_secrets.py"]
```

Build the image. I'll create an Azure Container Registry and build there, and then link that ACR to my AKS cluster.

```bash
# Create the ACR
az acr create -g $RG -n $ACR_NAME --sku Standard

# Build the image
az acr build -t wi-kv-test -r $ACR_NAME -g $RG .

# Link the ACR to the AKS cluster
az aks update -g $RG -n $CLUSTER_NAME --attach-acr $ACR_NAME
```

Now deploy a pod that gets the value using the service account identity.

```bash

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: wi-kv-test
  namespace: default
  labels:
    azure.workload.identity/use: "true"  
spec:
  serviceAccountName: wi-demo-sa
  nodeSelector:
    kubernetes.azure.com/agentpool: nodepool1
  containers:
    - image: ${ACR_NAME}.azurecr.io/wi-kv-test
      imagePullPolicy: Always
      name: wi-kv-test
      env:
      - name: KEY_VAULT_NAME
        value: ${KEY_VAULT_NAME}
      - name: SECRET_NAME
        value: Secret
EOF

# Check the pod logs
kubectl logs -f wi-kv-test

# Sample Output
Retrieving your secret from wilab4521.
Secret value: Hello
```

## Steal the secret!

A container is just a linux process that spawns other processes with some isolation, however, with the right priviledge on the node you can really get any information out of that process you want, including dumping memory. In the next step we'll run a debug pod and edit a system setting to enable us to access memory, reboot the node and then read the application memory of the running pod.

### Enable non-parent scoped ptrace

Ubuntu by default will only allow you to trace processes for which you are the parent, but as a root user we can change that option by editing /etc/sysctl.d/10-ptrace.conf

```bash
# Get the Node Name
NODE_NAME=$(kubectl get pod wi-kv-test -o jsonpath='{.spec.nodeName}')

kubectl debug node/$NODE_NAME -it --image=mcr.microsoft.com/dotnet/runtime-deps:6.0

# In the pod
chroot /host
sudo su

# edit the ptrace config to allow node level
# set the scope to zero as noted below
# kernel.yama.ptrace_scope = 0
nano /etc/sysctl.d/10-ptrace.conf

# Reboot the node
reboot 
```

Now reconnect to the same node.

>**NOTE:** For demo purposes we made it easy on ourselves and output the memory address from the python app itself. With the right commands and time you can get the memory location and take a memory dump easily. This is just to speed up our demo.

```bash
# Get the Node Name
NODE_NAME=$(kubectl get pod wi-kv-test -o jsonpath='{.spec.nodeName}')

kubectl debug node/$NODE_NAME -it --image=mcr.microsoft.com/dotnet/runtime-deps:6.0

# In the pod
chroot /host
sudo su

# Get the PID of the running app
ps -aux|grep /app/kv_secrets.py

# Set the PID 
PID=<pid from above>
MEMORY_ADDR=<memory address from containerlog output>

# Now to dump the python app memory at the memory address of our secret
dd bs=1 skip="$MEMORY_ADDR" count=200 if="/proc/$PID/mem" |  hexdump -C
```

You should have seen the secret value in the memory dump. Now lets protect it with kata.

## Protect the app in a confidential container

Taking the exact same container, and pod manifest, only adding ```runtimeClassName: kata-cc-isolation``` we can secure the pod compute and memory.

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: wi-kv-test-kata-cc
  namespace: default
  labels:
    azure.workload.identity/use: "true"  
spec:
  runtimeClassName: kata-cc-isolation
  serviceAccountName: wi-demo-sa
  # nodeSelector:
  #   kubernetes.azure.com/agentpool: nodepool1
  containers:
    - image: ${ACR_NAME}.azurecr.io/wi-kv-test
      imagePullPolicy: Always
      name: wi-kv-test
      env:
      - name: KEY_VAULT_NAME
        value: ${KEY_VAULT_NAME}
      - name: SECRET_NAME
        value: Secret
EOF
```

Try to get the process.

```bash
# Get the Node Name
NODE_NAME_KATA=$(kubectl get pod wi-kv-test-kata-cc -o jsonpath='{.spec.nodeName}')

kubectl debug node/$NODE_NAME_KATA -it --image=mcr.microsoft.com/dotnet/runtime-deps:6.0

# In the pod
chroot /host
sudo su

# Get the PID of the running app
# You should not see the running process any more
ps -aux|grep /app/kv_secrets.py
```