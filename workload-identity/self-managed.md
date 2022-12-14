# Using Workload Identity with Self Managed Clusters

### Cluster Creation

For this walk through I created my cluster from scratch using kubeadm, testing on both Azure and Google Cloud. The kubeadm setup directions I followed are linked below:

[https://computingforgeeks.com/deploy-kubernetes-cluster-on-ubuntu-with-kubeadm/](https://computingforgeeks.com/deploy-kubernetes-cluster-on-ubuntu-with-kubeadm/)

Once running you need to copy the sa.pub file from your kubernetes master node to the location where you'll be running your Azure CLI. This file is located at /etc/kubernetes/pki/sa.pub


### Create the Discovery Document in Blob Storage

Using the upstream document [here](https://azure.github.io/azure-workload-identity/docs/installation/self-managed-clusters/oidc-issuer/discovery-document.html).

```bash
export RESOURCE_GROUP="oidcissuer"
export LOCATION="eastus"

# Create the resource group
az group create --name "${RESOURCE_GROUP}" --location "${LOCATION}"

# Generate a unique name for the storage account
export AZURE_STORAGE_ACCOUNT="oidcissuer$(openssl rand -hex 4)"
export AZURE_STORAGE_CONTAINER="oidc-test"

# Create the storage account
az storage account create --resource-group "${RESOURCE_GROUP}" --name "${AZURE_STORAGE_ACCOUNT}"
az storage container create --name "${AZURE_STORAGE_CONTAINER}" --public-access container

# Generate the oidc well known configuration document
cat <<EOF > openid-configuration.json
{
  "issuer": "https://${AZURE_STORAGE_ACCOUNT}.blob.core.windows.net/${AZURE_STORAGE_CONTAINER}/",
  "jwks_uri": "https://${AZURE_STORAGE_ACCOUNT}.blob.core.windows.net/${AZURE_STORAGE_CONTAINER}/openid/v1/jwks",
  "response_types_supported": [
    "id_token"
  ],
  "subject_types_supported": [
    "public"
  ],
  "id_token_signing_alg_values_supported": [
    "RS256"
  ]
}
EOF

# Upload the well known configuration document to the blob storage account
az storage blob upload \
  --container-name "${AZURE_STORAGE_CONTAINER}" \
  --file openid-configuration.json \
  --name .well-known/openid-configuration

# Test the endpoint
curl -s "https://${AZURE_STORAGE_ACCOUNT}.blob.core.windows.net/${AZURE_STORAGE_CONTAINER}/.well-known/openid-configuration"
```


### Create the Json Web Key Sets (jswk) file

Following the guide [here](https://azure.github.io/azure-workload-identity/docs/installation/self-managed-clusters/oidc-issuer/jwks.html), use the azwi cli to generate the jwks.json file using the sa.pub file created above. You'll need to make sure you've installed the azwi cli [here](https://azure.github.io/azure-workload-identity/docs/installation/azwi.html)

> *Note:* You'll use the sa.pub file you copied from your Kuberenetes master node above.

```bash
# Generate the jwks file
azwi jwks --public-keys sa.pub --output-file jwks.json

# Upload the jwks.json file to the blob account
az storage blob upload \
  --container-name "${AZURE_STORAGE_CONTAINER}" \
  --file jwks.json \
  --overwrite \
  --name openid/v1/jwks

# Test the file
curl -s "https://${AZURE_STORAGE_ACCOUNT}.blob.core.windows.net/${AZURE_STORAGE_CONTAINER}/openid/v1/jwks"
```

Next you need to update the kube-apiserver configuration on your Kubernetes master node. First let's output the issuer URL.

```bash
# Get the issuer url
echo Issuer: "https://${AZURE_STORAGE_ACCOUNT}.blob.core.windows.net/${AZURE_STORAGE_CONTAINER}/"

# Sample Output
Issuer: https://oidcissuer4e2fd2e1.blob.core.windows.net/oidc-test/
```

Now SSH back to the master node to edit the kube-apiserver static manifest.

```bash
# Edit the kube-apiserver manifest
nano /etc/kubernetes/manifests/kube-apiserver.yaml 

# Set the service-account-issuer value to the first URL
# Add the service-account-jwks-uri value and set it to the second URL
# The service-account settings should look like the following given the URLs above:

    - --service-account-issuer=https://oidcissuer4e2fd2e1.blob.core.windows.net/oidc-test/
    - --service-account-key-file=/etc/kubernetes/pki/sa.pub
    - --service-account-signing-key-file=/etc/kubernetes/pki/sa.key

# Save and exit.
```

The above change will cause the API server to restart, so it may take a minute or two before the pods are back online and the API server is accessible.

### Install the MutatingWebhook

Back at the terminal where you have your Azure CLI and access to the cluster via kubectl, we'll install the workload identity components.

```bash
# Get your Azure Active Directory Tenant ID
export AZURE_TENANT_ID=$(az account show -o tsv --query homeTenantId)

# Install the MutatingWebhook
helm repo add azure-workload-identity https://azure.github.io/azure-workload-identity/charts
helm repo update
helm install workload-identity-webhook azure-workload-identity/workload-identity-webhook \
   --namespace azure-workload-identity-system \
   --create-namespace \
   --set azureTenantID="${AZURE_TENANT_ID}"

# Check the installation
kubectl get pods -n azure-workload-identity-system

# Sample Output
NAME                                                   READY   STATUS    RESTARTS       AGE
azure-wi-webhook-controller-manager-747c86695f-9jrk5   1/1     Running   20 (48m ago)   94m
azure-wi-webhook-controller-manager-747c86695f-vrpkr   1/1     Running   20 (49m ago)   94m
```

### Test

Now the cluster is configured with all the components needed to enable service account federation and Azure Workload Identity. Lets test it out. We'll create a new service account and managed identity and federate them. We'll also create a key vault we can use to test the service account federation.

> *Note:* We'll reuse the resource group variable from above, so you may need to reset it if you have a new terminal session.

```bash
# Set the managed identity and oidc issuer variables
MANAGED_IDENTITY_NAME=testmi
OIDC_ISSUER=<Get the oidc issuer url from above>

# Create the managed identity
az identity create --name $MANAGED_IDENTITY_NAME --resource-group $RESOURCE_GROUP

# Get the client ID
export USER_ASSIGNED_CLIENT_ID=$(az identity show --resource-group $RESOURCE_GROUP --name $MANAGED_IDENTITY_NAME --query 'clientId' -o tsv)

# Create the namespace and service account
NAMESPACE=wi-test

kubectl create ns $NAMESPACE

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  annotations:
    azure.workload.identity/client-id: ${USER_ASSIGNED_CLIENT_ID}
  labels:
    azure.workload.identity/use: "true"
  name: ${MANAGED_IDENTITY_NAME}-sa
  namespace: ${NAMESPACE}
EOF

# Federate the service account and managed identity
az identity federated-credential create \
--name $MANAGED_IDENTITY_NAME-federated-id \
--identity-name $MANAGED_IDENTITY_NAME \
--resource-group $RESOURCE_GROUP \
--issuer ${OIDC_ISSUER} \
--subject system:serviceaccount:$NAMESPACE:$MANAGED_IDENTITY_NAME-sa
```

For testing purposes we'll create a key vault and a secret which is authorized for read access by the managed identity we created above.

```bash
KEY_VAULT_NAME=vault$(openssl rand -hex 4)

# Create a key vault
az keyvault create --name $KEY_VAULT_NAME --resource-group $RESOURCE_GROUP

# Create a secret
az keyvault secret set --vault-name $KEY_VAULT_NAME --name "Secret" --value "Hello from key vault"

# Grant access to the secret for the managed identity using it's AAD client ID
az keyvault set-policy --name $KEY_VAULT_NAME --secret-permissions get --spn "${USER_ASSIGNED_CLIENT_ID}"

```

For the test app we'll use a Key Vault test container I created previously. You can see the code [here](https://github.com/Azure/reddog-aks-workshop/blob/main/docs/cheatsheets/workload-identity-cheatsheet.md#write-the-code-to-test-your-workload-identity-setup)

Deploy the test app:

```bash
# Deploy the app
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: wi-kv-test
  namespace: ${NAMESPACE}
spec:
  serviceAccountName: ${MANAGED_IDENTITY_NAME}-sa
  containers:
    - image: stevegriffith/wi-kv-test
      name: wi-kv-test
      env:
      - name: KEY_VAULT_NAME
        value: ${KEY_VAULT_NAME}
      - name: SECRET_NAME
        value: Secret    
  nodeSelector:
    kubernetes.io/os: linux
EOF

# Check the pod is running
kubectl get pods -n $NAMESPACE

# Sample Output
NAME         READY   STATUS    RESTARTS   AGE
wi-kv-test   1/1     Running   0          19s

# Check the pod logs to confirm it's connecting to key vault with the authorized managed identity
kubectl logs -f wi-kv-test -n $NAMESPACE

# Sample output
Retrieving your secret from vault70abc350.
Your secret is 'Hello from key vault'.
Retrieving your secret from vault70abc350.
Your secret is 'Hello from key vault'.
Retrieving your secret from vault70abc350.
Your secret is 'Hello from key vault'.
Retrieving your secret from vault70abc350.
Your secret is 'Hello from key vault'.
```

## Conclusion

You should now have a working setup of Azure Workload Identity in your self managed cluster, connecting to keyvault to retrieve a secret via an authorized managed identity which has been federated to a kubernetes service account used by the application pod.