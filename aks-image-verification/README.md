# AKS Image Integrity (Preview)

In this walkthrough I'll demonstrate the ability to sign and verify container images in AKS using [Notation](https://github.com/notaryproject/notation), Azure Key Vault as the signing certificate store and [AKS Image Integrity](https://learn.microsoft.com/en-us/azure/aks/image-integrity?tabs=azure-cli). 

>**NOTE:** AKS Image verification is currently in preview, so it is not ready for production use at this time. If you're comfortable running the key component of image verification, [Ratify](https://ratify.dev/), yourself then you can see my other post that demonstrates setting up and running Ratify [here](https://azureglobalblackbelts.com/2023/11/09/part2-aks-image-verification.html).

## Setup

### Enable Features

As image verification is in preview, we need to enable some features first to get it working.

```bash
# Register the EnableImageIntegrityPreview feature flag
az feature register --namespace "Microsoft.ContainerService" --name "EnableImageIntegrityPreview"

# Register the AKS-AzurePolicyExternalData feature flag
az feature register --namespace "Microsoft.ContainerService" --name "AKS-AzurePolicyExternalData"

# Verify the EnableImageIntegrityPreview feature flag registration status
az feature show --namespace "Microsoft.ContainerService" --name "EnableImageIntegrityPreview"

# Verify the AKS-AzurePolicyExternalData feature flag registration status
az feature show --namespace "Microsoft.ContainerService" --name "AKS-AzurePolicyExternalData"

az provider register --namespace Microsoft.ContainerService
```

## Cluster Setup

>**Note:** When creating the cluster Ratify will use Workload Identity to access the ACR and Key Vault, so we need to enable workload identity and the OIDC issuer. 

```bash
# Set Environment Variables
RG=ImageIntegrityLab
LOC=eastus2
CLUSTER_NAME=imgintegritylab-aks
ACR_NAME=imageintegritylab
SUBSCRIPTION=$(az account show -o tsv --query id)

# Create the resource group
az group create -n $RG -l $LOC

# Create the Azure Container Registry
az acr create -g $RG -n $ACR_NAME --sku Standard

# Create the AKS Cluster
az aks create -g $RG -n $CLUSTER_NAME \
--enable-addons azure-policy \
--enable-oidc-issuer \
--enable-workload-identity \
--attach-acr $ACR_NAME \
-c 1

# Get the cluster credentials
az aks get-credentials -g $RG -n $CLUSTER_NAME
```

### Enable the Image Integrity Policy

Typically, you would use a policy engine to enforce image verification, so the recommended approach is to enable image integrity via Azure Policy.

```bash
# Set the scope for the Policy. We'll set at the cluster resource group level, but you could go higher.
SCOPE=$(az group show -n $RG --query id -o tsv)

# Assign the 'deploy-trustedimages' policy
az policy assignment create --name 'deploy-trustedimages' --policy-set-definition 'af28bf8b-c669-4dd3-9137-1e68fdc61bd6' --display-name 'Audit deployment with unsigned container images' --scope ${SCOPE} --mi-system-assigned --role Contributor --identity-scope ${SCOPE} --location ${LOC}

# Get the assignment ID
ASSIGNMENT_ID=$(az policy assignment show --name 'deploy-trustedimages' --scope ${SCOPE} --query id -o tsv)

# You can speed up the application of the policy on the cluster by applying a remediation
az policy remediation create --policy-assignment "$ASSIGNMENT_ID" --definition-reference-id deployAKSImageIntegrity --name remediation --resource-group ${RG}
```

At this point you'll need to wait for the gatekeeper and ratify components to be deployed via policy. You can watch the status and once the pods are running you can move on to the next step.

>**NOTE:** I have seen cases where you may need to re-run the remediation command for the remediation to complete.

```bash
watch kubectl get pods -n gatekeeper-system

# Sample output when ready
NAME                                     READY   STATUS    RESTARTS   AGE
gatekeeper-audit-7bd8cb9f77-dvvgb        1/1     Running   0          24m
gatekeeper-controller-54694cd6c5-g2smw   1/1     Running   0          24m
gatekeeper-controller-54694cd6c5-hvllf   1/1     Running   0          24m
ratify-7f89f4d89b-7drx6                  1/1     Running   0          46s

```

### Setup the Ratify Managed Identity

Ratify will need to access Azure Container Registry to get the image signature info and Azure Key Vault to get the signing certificate, so we'll set that up now. 

```bash
# Get the managed cluster resource group
MC_RESOURCE_GROUP=$(az aks show -g $RG -n $CLUSTER_NAME -o tsv --query nodeResourceGroup)

# Set the identity name for the ratify managed identity
IDENTITY_NAME="azurepolicy-${CLUSTER_NAME}"

# Get the managed identity object and client ids
export IDENTITY_OBJECT_ID="$(az identity show --name "azurepolicy-${CLUSTER_NAME}" --resource-group "${MC_RESOURCE_GROUP}" --query 'principalId' -otsv)"

export IDENTITY_CLIENT_ID=$(az identity show --name "azurepolicy-${CLUSTER_NAME}" --resource-group ${MC_RESOURCE_GROUP} --query 'clientId' -o tsv)

# Get the ACR resource ID
ACR_ID=$(az acr show -g $RG -n $ACR_NAME -o tsv --query id)

# Grant the ratify identity acr pull rights
az role assignment create \
--assignee-object-id ${IDENTITY_OBJECT_ID} \
--role acrpull \
--scope ${ACR_ID}

# Get the AKS Cluster OIDC Issuer URL
export AKS_OIDC_ISSUER="$(az aks show -n ${CLUSTER_NAME} -g ${RG} --query "oidcIssuerProfile.issuerUrl" -o tsv)"

# Federate the managed identity to the service account used by ratify
az identity federated-credential create \
--name ratify-federated-credential \
--identity-name "${IDENTITY_NAME}" \
--resource-group "${MC_RESOURCE_GROUP}" \
--issuer "${AKS_OIDC_ISSUER}" \
--subject system:serviceaccount:gatekeeper-system:ratify-admin

```

### Setup Key Vault and create the certificate

```bash
# Set the key vault name (must be unique)
AKV_NAME=imgintlab

# Create the key vault
az keyvault create --name $AKV_NAME --resource-group $RG --enable-rbac-authorization false

# Set some variables for the cert creation
# Name of the certificate created in AKV
CERT_NAME=brooklyn-io
CERT_SUBJECT="CN=brooklyn.io,O=Notation,L=Brooklyn,ST=NY,C=US"
CERT_PATH=./${CERT_NAME}.pem

# Set the access policy for yourself to create and get certs
USER_ID=$(az ad signed-in-user show --query id -o tsv)
az keyvault set-policy -n $AKV_NAME --certificate-permissions create get --key-permissions sign --object-id $USER_ID

# Set the access policy for the ratify managed identity
az keyvault set-policy --name ${AKV_NAME} \
--certificate-permissions get \
--secret-permissions get \
--object-id ${IDENTITY_OBJECT_ID}

# Create the Key Vault certificate policy file
cat <<EOF > ./${CERT_NAME}.json
{
    "issuerParameters": {
    "certificateTransparency": null,
    "name": "Self"
    },
    "keyProperties": {
      "exportable": false,
      "keySize": 2048,
      "keyType": "RSA",
      "reuseKey": true
    },
    "secretProperties": {
        "contentType": "application/x-pem-file"
    },
    "x509CertificateProperties": {
    "ekus": [
        "1.3.6.1.5.5.7.3.3"
    ],
    "keyUsage": [
        "digitalSignature"
    ],
    "subject": "${CERT_SUBJECT}",
    "validityInMonths": 12
    }
}
EOF

# Create the signing certificate
az keyvault certificate create -n $CERT_NAME --vault-name $AKV_NAME -p @${CERT_NAME}.json

# Get the Key ID of the signing key
KEY_ID=$(az keyvault certificate show -n $CERT_NAME --vault-name $AKV_NAME --query 'kid' -o tsv)
```

### Sign a test image

We'll use the notation cli to sign a test image. For more information on using notation you can see my previous post [here](https://azureglobalblackbelts.com/2023/11/09/part1-notation-usage.html).

```bash
# Import a test image
az acr import --name $ACR_NAME --source docker.io/library/nginx:1.25.3 --image nginx:1.25.3
IMAGE_SHA=$(az acr repository show -n $ACR_NAME --image "nginx:1.25.3" -o tsv --query digest)

# Login to ACR
az acr login -n $ACR_NAME

# Now sign the previosly imported nginx image
# You should get a confirmation that the image was successfully signed
notation sign --signature-format cose --id $KEY_ID --plugin azure-kv --plugin-config self_signed=true $ACR_NAME.azurecr.io/nginx@$IMAGE_SHA

# Confirm the signature
notation ls $ACR_NAME.azurecr.io/nginx@$IMAGE_SHA
```

### Setup Ratify ACR Access

```bash
# Create the ORAS store config
cat <<EOF > store_config.yaml
apiVersion: config.ratify.deislabs.io/v1beta1
kind: Store
metadata:
  name: store-oras
spec:
  name: oras
  parameters:
    authProvider:
      name: azureWorkloadIdentity
      clientID: $IDENTITY_CLIENT_ID
      cosignEnabled: true
EOF

# Apply the store config
kubectl apply -f store_config.yaml
```

### Setup the Cert Store and Verifier

Now we'll set up the Certificate store and reference our certificate and version.

>**NOTE:** CertificateStore is being deprecated and replaced with 'KeyManagementProvider', however at the writing of this guide the managed add-on has not yet been updated.

```bash
# Get the Entra Tenant ID for the subscription
TENANT_ID=$(az account show -o tsv --query tenantId)

# Get the Azure Key Vault URI
AKV_URI=$(az keyvault show -g $RG -n $AKV_NAME -o tsv --query properties.vaultUri)

# Get the certificate version number
az keyvault secret show --vault-name $AKV_NAME --name $CERT_NAME -o tsv --query id

# Grab the last section of the above commands output and use that for the version ID
VERSION_ID=c53ad379d88d4cbe87c2bd3af2c29140

# Generate the Azure Key Vault Certificate Store Config
cat << EOF > akv-certificate-store.yaml
apiVersion: config.ratify.deislabs.io/v1beta1
kind: CertificateStore
metadata:
  name: certstore-akv
spec:
  provider: azurekeyvault
  parameters:
    vaultURI: ${AKV_URI}
    certificates:  |
      array:
        - |
          certificateName: ${CERT_NAME}
          certificateVersion: ${VERSION_ID} 
    tenantID: ${TENANT_ID}
    clientID: ${IDENTITY_CLIENT_ID}
EOF

# Apply the Azure Key Vault Certificate Store Config
kubectl apply -f akv-certificate-store.yaml

# Create the image verifier config
cat << EOF > akv-verifier.yaml
apiVersion: config.ratify.deislabs.io/v1beta1
kind: Verifier
metadata:
  name: verifier-notation
spec:
  name: notation
  artifactTypes: application/vnd.cncf.notary.signature
  parameters:
    verificationCertStores:
      certs:
          - certstore-akv
    trustPolicyDoc:
      version: "1.0"
      trustPolicies:
        - name: default
          registryScopes:
            - "*"
          signatureVerification:
            level: strict
          trustStores:
            - ca:certs
          trustedIdentities:
            - "*"
EOF

# Apply the image verifier config
kubectl apply -f akv-verifier.yaml

# Check the status of the cert store and verifier
kubectl get certificatestore,verifier

# Sample Output
NAME                                                       ISSUCCESS   ERROR   LASTFETCHEDTIME
certificatestore.config.ratify.deislabs.io/certstore-akv   true                79s

NAME                                                   AGE
verifier.config.ratify.deislabs.io/verifier-notation   28s
```

### Deploy Test Pods

Now we can test verification is working. While in preview, the default policy applied is in 'Audit' mode rather than enforce. So creation of pods will not fail, but you will see warnings in Azure Policy. For our test, lets just watch the ratify logs as we deploy pods.

Open two terminal windows.

```bash
# In terminal #1
# Follow ratify pod logs
kubectl logs -f -l app=ratify -n gatekeeper-system

# In interminal #2

# Deploy a test pod with no signature
# You should see errors in terminal #1
kubectl run demo-fail --namespace default --image=nginx:latest

# Deploy a pod with a container we signed previously
# You shoud see a 'signature verification success' message in terminal #1
kubectl run demo-pass --namespace default --image=$ACR_NAME.azurecr.io/nginx@$IMAGE_SHA

```

## Conclusion

Congrats! You should now have an AKS cluster enabled, via Azure Policy with the managed image integrity add on using Azure Key Vault to store and maintain the signing certificate!

As mentioned above, this feature is still in preview and has more capability to come, but you should now have an idea of the moving parts.