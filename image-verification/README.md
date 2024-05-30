# Image Integrity

## Enable Features

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

```bash
RG=EphImageIntegrity
LOC=eastus
CLUSTER_NAME=imgintegrity
ACR_NAME=imgverificationgriff
SUBSCRIPTION=$(az account show -o tsv --query id)

az group create -n $RG -l $LOC

az aks create -g $RG -n $CLUSTER_NAME --enable-addons azure-policy

az acr create -g $RG -n $ACR_NAME --sku Standard

az aks update -g $RG -n $CLUSTER_NAME --attach-acr $ACR_NAME


SCOPE="/subscriptions/${SUBSCRIPTION}/resourceGroups/${RG}"

az policy assignment create --name 'deploy-trustedimages' --policy-set-definition 'af28bf8b-c669-4dd3-9137-1e68fdc61bd6' --display-name 'Audit deployment with unsigned container images' --scope ${SCOPE} --mi-system-assigned --role Contributor --identity-scope ${SCOPE} --location ${LOC}
```

## Setup Key Vault

```bash
AKV_NAME=mynotationtest2

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

# Create the Key Vault certificate policy file
cat <<EOF > ./brooklyn_io_policy.json
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
    "subject": "CN=brooklyn.io,O=Notation,L=Brooklyn,ST=NY,C=US",
    "validityInMonths": 12
    }
}
EOF

# Create the signing certificate
az keyvault certificate create -n $CERT_NAME --vault-name $AKV_NAME -p @brooklyn_io_policy.json

# Get the Key ID of the signing key
KEY_ID=$(az keyvault certificate show -n $CERT_NAME --vault-name $AKV_NAME --query 'kid' -o tsv)

# Now sign the previosly imported nginx image
# You should get a confirmation that the image was successfully signed
notation sign --signature-format cose --id $KEY_ID --plugin azure-kv --plugin-config self_signed=true $ACR_NAME.azurecr.io/nginx@$IMAGE_SHA

# Confirm the signature
notation ls $ACR_NAME.azurecr.io/nginx@$IMAGE_SHA
```