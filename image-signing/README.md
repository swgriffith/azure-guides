# Container Image Signing and Verification

## Setup

* Install [notation](https://notaryproject.dev/docs/user-guides/installation/cli/)
* Docker must be running locally 

```bash
# Install notation (mac)
brew install notation

# Create an Azure Container Registry
RG=EphNotationLab
LOC=eastus
ACR_NAME=griffnotationlab

# Create the resource group
az group create -n $RG -l $LOC

# Create the Azure Container Registry
az acr create -g $RG -n $ACR_NAME --sku Standard

# Login to the ACR
az acr login -n $ACR_NAME

# Build a test image
docker build -t $ACR_NAME.azurecr.io/net-monitor:v1 https://github.com/wabbit-networks/net-monitor.git#main

# Push the image
docker push $ACR_NAME.azurecr.io/net-monitor:v1

# For later testing, lets also import an unsigned image
az acr import --name $ACR_NAME --source docker.io/library/nginx:latest --image nginx:latest
```

## Working with Notation

```bash
# Get the image SHA
IMAGE_SHA=$(az acr repository show -n $ACR_NAME --image "net-monitor:v1" -o tsv --query digest)

# List the signatures on the image
# You should see the image has no signatures
notation ls $ACR_NAME.azurecr.io/net-monitor@$IMAGE_SHA

# Generate a test RSA key and self-signed certificat
notation cert generate-test --default "brooklyn.io"

# List certs to confirm the cert exists
notation cert ls

# Sign the image
notation sign $ACR_NAME.azurecr.io/net-monitor@$IMAGE_SHA

# Now check the image signatures
# You should now see that the image is signed
notation ls $ACR_NAME.azurecr.io/net-monitor@$IMAGE_SHA

# Create a trust policy for notation
cat <<EOF > ./trustpolicy.json
{
    "version": "1.0",
    "trustPolicies": [
        {
            "name": "brooklyn-images",
            "registryScopes": [ "*" ],
            "signatureVerification": {
                "level" : "strict"
            },
            "trustStores": [ "ca:brooklyn.io" ],
            "trustedIdentities": [
                "*"
            ]
        }
    ]
}
EOF

# Import the policy
notation policy import ./trustpolicy.json

# Show the policy
notation policy show

# Verify the image meets the policy
# You should get a message that the signature was verified
notation verify $ACR_NAME.azurecr.io/net-monitor@$IMAGE_SHA

# Check the unsigned test image we imported above
TEST_IMAGE_SHA=$(az acr repository show -n $ACR_NAME --image "nginx" -o tsv --query digest)

# This should return an error:
# Error: signature verification failed: no signature is associated
notation verify $ACR_NAME.azurecr.io/nginx@$TEST_IMAGE_SHA

# Now sign the test image
notation sign $ACR_NAME.azurecr.io/nginx@$TEST_IMAGE_SHA

# Verify again. This time it should succeed
notation verify $ACR_NAME.azurecr.io/nginx@$TEST_IMAGE_SHA

```

## Sign images with Azure Key Vault

First you need to install the Azure Key Vault plug-in for notation. You can find instructions for you OS [here](https://github.com/Azure/notation-azure-kv#installation-the-akv-plugin).

```bash
# Confirm you successfuly installed the plugin
notation plugin list

# Sample Output
NAME       DESCRIPTION                       VERSION   CAPABILITIES                ERROR
azure-kv   Notation Azure Key Vault plugin   1.0.1     [SIGNATURE_GENERATOR.RAW]   <nil>
```

Now we'll create an Azure Key Vault instance for our test and configure the signature.

```bash
AKV_NAME=griffnotationtest

# Create the key vault
az keyvault create --name $AKV_NAME --resource-group $RG

# Set some variables for the cert creation
# Name of the certificate created in AKV
CERT_NAME=brooklyn-io
CERT_SUBJECT="CN=brooklyn.io,O=Notation,L=Brooklyn,ST=NY,C=US"
CERT_PATH=./${CERT_NAME}.pem

# Set the access policy
USER_ID=$(az ad signed-in-user show --query id -o tsv)
az keyvault set-policy -n $AKV_NAME --certificate-permissions create get --key-permissions sign --object-id $USER_ID

# Create the certificate policy file
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
    "x509CertificateProperties": {
    "ekus": [
        "1.3.6.1.5.5.7.3.3"
    ],
    "keyUsage": [
        "digitalSignature"
    ],
    "subject": "$CERT_SUBJECT",
    "validityInMonths": 12
    }
}
EOF

# Create the signing certificate
az keyvault certificate create -n $CERT_NAME --vault-name $AKV_NAME -p @brooklyn_io_policy.json
```