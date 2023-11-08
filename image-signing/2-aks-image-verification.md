# Image Verification with Gatekeeper and Ratify

## Introduction

In the prior post, we ran through using the notation cli tool to sign images in Azure Container Registry. If you havent gone through that post, I recommend you start there at [Part 1 - Image Signing with Notation](./1-notation-usage.md)

In this post, we'll walk through the steps to manually configure AKS with Gatekeeper and the Ratify project to enforce an image signature verification policy.

## Cluster Creation and Setup

For Ratify to work with Gatekeeper, we'll need a cluster with both the OIDC Issuer and Workload Idenitty add-ons enabled.

```bash
# Set environment variables
RG=EphNotationTesting
LOC=eastus
ACR_NAME=mynotationlab
CLUSTER_NAME=imagesigninglab

# Create the AKS Cluster
az aks create -g $RG -n $CLUSTER_NAME \
--attach-acr $ACR_NAME \
--enable-oidc-issuer \
--enable-workload-identity

# Get the cluster credentials
az aks get-credentials -g $RG -n $CLUSTER_NAME

export AKS_OIDC_ISSUER="$(az aks show -n ${CLUSTER_NAME} -g ${RG} --query "oidcIssuerProfile.issuerUrl" -otsv)"
```

## Managed Identity Setup

Ratify will need to be able to read from the Key Vault, so we'll need to create a managed identity and grant it the proper rights on Azure Key Vault

```bash
SUBSCRIPTION=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxx
TENANT_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxx
IDENTITY_NAME=ratify-identity
RATIFY_NAMESPACE=gatekeeper-system

# Create the ratify identity
az identity create --name "${IDENTITY_NAME}" --resource-group "${RG}" --location "${LOC}" --subscription "${SUBSCRIPTION}"

# Get the identity IDs
export IDENTITY_OBJECT_ID="$(az identity show --name "${IDENTITY_NAME}" --resource-group "${RG}" --query 'principalId' -otsv)"
export IDENTITY_CLIENT_ID=$(az identity show --name ${IDENTITY_NAME} --resource-group ${RG} --query 'clientId' -o tsv)

# Grant the ratify identity acr pull rights
az role assignment create \
--assignee-object-id ${IDENTITY_OBJECT_ID} \
--role acrpull \
--scope subscriptions/${SUBSCRIPTION}/resourceGroups/${RG}/providers/Microsoft.ContainerRegistry/registries/${ACR_NAME}

# Federate the managed identity to the service account used by ratify
az identity federated-credential create \
--name ratify-federated-credential \
--identity-name "${IDENTITY_NAME}" \
--resource-group "${RG}" \
--issuer "${AKS_OIDC_ISSUER}" \
--subject system:serviceaccount:"${RATIFY_NAMESPACE}":"ratify-admin"
```

Now we can grant the Ratify identity permissions on the Azure Key Vault.

```bash
# Grant the ratify identity rights
az keyvault set-policy --name ${AKV_NAME} \
--secret-permissions get \
--object-id ${IDENTITY_OBJECT_ID}
```

## Install Gatekeeper and Ratify

While AKS does, now in preview, have a [managed add-on for gatekeeper and ratify](https://learn.microsoft.com/en-us/azure/aks/image-integrity?tabs=azure-cli), it's still a work in progress, so we'll manually install to make sure we understand all the moving parts. 

```bash
# Install Gatekeeper
helm repo add gatekeeper https://open-policy-agent.github.io/gatekeeper/charts

helm install gatekeeper/gatekeeper  \
    --name-template=gatekeeper \
    --namespace ${RATIFY_NAMESPACE} --create-namespace \
    --set enableExternalData=true \
    --set validatingWebhookTimeoutSeconds=5 \
    --set mutatingWebhookTimeoutSeconds=2

# Get the key vault URI which ratify will need
export VAULT_URI=$(az keyvault show --name ${AKV_NAME} --resource-group ${RG} --query "properties.vaultUri" -otsv)

# Install Ratify
helm repo add ratify https://deislabs.github.io/ratify

helm install ratify \
    ratify/ratify --atomic \
    --namespace ${RATIFY_NAMESPACE} --create-namespace \
    --set featureFlags.RATIFY_CERT_ROTATION=true \
    --set akvCertConfig.enabled=true \
    --set akvCertConfig.vaultURI=${VAULT_URI} \
    --set akvCertConfig.cert1Name=${CERT_NAME} \
    --set akvCertConfig.tenantId=${TENANT_ID} \
    --set oras.authProviders.azureWorkloadIdentityEnabled=true \
    --set azureWorkloadIdentity.clientId=${IDENTITY_CLIENT_ID}
```

Now that gatekeeper and ratify are running, lets apply a new constraint and policy template for the image verification policy. You should inspect the two files in the commands below for your own knowledge of how they work.

```bash
# Create the gatekeeper policy template
kubectl apply -f ratify-policy-template.yaml

# Apply the policy with a gatekeeper constraint
kubectl apply -f ratify-policy-constraint.yaml
```

## Test the policy!

Our setup is complete. We can now try to create a pod using an unsigned and signed container image.

```bash
# First try to use the docker hub nginx image, which is unsigned
# This should fail
kubectl run demo --namespace default --image=nginx:latest

# Sample Error Message
Error from server (Forbidden): admission webhook "validation.gatekeeper.sh" denied the request: [ratify-constraint] Subject failed verification: docker.io/library/nginx@sha256:86e53c4c16a6a276b204b0fd3a8143d86547c967dc8258b3d47c3a21bb68d3c6

# Now try using our container image
# This pod should be successfully created!
kubectl run demo --namespace default --image=$ACR_NAME.azurecr.io/nginx@$IMAGE_SHA
```

## Conclusion

Between this post and [Part 1](./1-notation-usage.md), we learned about the notation cli tool, which can be used to sign container images via the notary specification. We signed images with both local self signed certificates, as well as certificates generated by Azure Key Vault. Finally, we enabled Gatekeeper and Ratify on an AKS cluster to provide an image signature verification policy.