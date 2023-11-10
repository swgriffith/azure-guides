# Using Workload Identity with Python

In this walk through we'll set up an AKS cluster with Workload Identity enabled and build a python app that reads a value from Azure Key Vault.

### Cluster Creation

Now lets create the AKS cluster with the OIDC Issure and Workload Identity add-on enabled.

```bash
export RG=WorkloadIdentityRG
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

```bash
# Create a key vault
az keyvault create --name $KEY_VAULT_NAME --resource-group $RG --location $LOC

USER_ID=$(az ad signed-in-user show --query id -o tsv)
az keyvault set-policy -n $KEY_VAULT_NAME --certificate-permissions get --object-id $USER_ID

# Create a secret
az keyvault secret set --vault-name $KEY_VAULT_NAME --name "Secret" --value "Hello"

# Grant access to the secret for the managed identity
az keyvault set-policy --name $KEY_VAULT_NAME --secret-permissions get --spn "${USER_ASSIGNED_CLIENT_ID}"

# Get the version ID
az keyvault secret show --vault-name $KEY_VAULT_NAME --name "Secret" -o tsv --query id
https://wi-demo-keyvault.vault.azure.net/secrets/Secret/ded8e5e3b3e040e9bfa5c47d0e28848a

# The version ID is the last part of the resource id above
# We'll use this later
VERSION_ID=695dfd4c7b594d75a2f6efd643f22368
```

## Create the sample python app

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
    retrieved_secret = client.get_secret(secretName)
    print(f"Secret value: {retrieved_secret.value}")
    time.sleep(5)
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
az acr build -t wi-kv-test -r $ACR_NAME .

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
  containers:
    - image: ${ACR_NAME}.azurecr.io/wi-kv-test
      imagePullPolicy: Always
      name: wi-kv-test
      env:
      - name: KEY_VAULT_NAME
        value: ${KEY_VAULT_NAME}
      - name: SECRET_NAME
        value: Secret     
  nodeSelector:
    kubernetes.io/os: linux
EOF

# Check the pod logs
kubectl logs -f wi-kv-test

# Sample Output
Retrieving your secret from wilab4521.
Secret value: Hello
```

### Conclusion

Congrats! You should now have a working pod that uses MSAL along with a Kubernetes Service Account federated to an Azure Managed Identity to access and Azure Key Vault Secret.