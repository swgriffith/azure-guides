# Image Signing with Notation

## Introduction

This is part one of a 2 part post on container image signing and runtime verification. In this post, we'll walk through the [notation](https://github.com/notaryproject/notation) project and it's ability to sign container images, using the [Notary](https://github.com/notaryproject/specifications) project specification. In the next post, we'll walk through setting up [gatekeeper](https://open-policy-agent.github.io/gatekeeper/website/) and [ratify](https://github.com/deislabs/ratify/blob/main/README.md) to perform policy based runtime verification of images.

## Installation

For this walk through you'll need to have Docker running locally, and have the notary cli installed. You can find the install steps for each in the list below:

* [Docker](https://www.docker.com/get-started/)
* [Notation CLI](https://notaryproject.dev/docs/user-guides/installation/cli/)

## Azure Container Registry

You can really use any OCI compatible registry, but since we'll later be using AKS for verification, we'll create an Azure Container Registery for use in the following steps.

```bash
# Setup Environment Variables
RG=EphNotationTesting
LOC=eastus
ACR_NAME=mynotationlab

# Create the resource group
az group create -n $RG -l $LOC

# Create the Azure Container Registry
az acr create -g $RG -n $ACR_NAME --sku Standard

# Login to the ACR
az acr login -n $ACR_NAME
```

We could build our own container image from scratch, but the image signing process doesnt really change, so let's just import an existing image to use. This is a good demonstration of the best practice of never pulling public images. Instead, you should import and verify any public images you wish to use. We'll improve that by also signing the imported image.

```bash
# For later testing, lets also import an unsigned image
az acr import --name $ACR_NAME --source docker.io/library/nginx:1.25.3 --image nginx:1.25.3
```

Now we can play around with notation. Notation does require you use the image SHA instead of tags, so we'll get that first.

```bash
# Get the nginx image SHA
IMAGE_SHA=$(az acr repository show -n $ACR_NAME --image "nginx:1.25.3" -o tsv --query digest)

# List the signatures on the image
# You should see the image has no signatures
notation ls $ACR_NAME.azurecr.io/nginx@$IMAGE_SHA

# Generate a test RSA key and self-signed certificat
notation cert generate-test --default "brooklyn.io"

# List certs to confirm the cert exists
notation cert ls

# Sign the image
notation sign $ACR_NAME.azurecr.io/nginx@$IMAGE_SHA

# Now check the image signatures
# You should now see that the image is signed
notation ls $ACR_NAME.azurecr.io/nginx@$IMAGE_SHA
```

Now that we've signed an image successfully, we need can also use notation to verify the image has been signed. For that we'll need to create a local trust policy for notation.

```bash
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
notation verify $ACR_NAME.azurecr.io/nginx@$IMAGE_SHA
```

## Cleanup

Before moving on, we should delete and re-import the image, since we dont want the local test certificate on the image any more. You can also remove the signature with [oras](https://notaryproject.dev/docs/user-guides/how-to/manage-signatures/#delete-a-signature-on-an-artifact)

```bash
# Delete and re-import the image
az acr repository delete -n $ACR_NAME --repository nginx -y
az acr import --name $ACR_NAME --source docker.io/library/nginx:1.25.3 --image nginx:1.25.3
IMAGE_SHA=$(az acr repository show -n $ACR_NAME --image "nginx:1.25.3" -o tsv --query digest)
```

## Sign Images with a Cert from Azure Key Vault

Using self signed certificates does give you some level of comfort about the source of the image, but you really want to use a certificate from a trusted store. Fortunately, notation provides a plugin for Azure Key Vault which can be used to sign images with certifiates source from Azure Key Vault.

First you need to install the Azure Key Vault plug-in for notation. You can find instructions for your OS [here](https://github.com/Azure/notation-azure-kv#installation-the-akv-plugin).

```bash
# Confirm you successfuly installed the plugin
notation plugin list

# Sample Output
NAME       DESCRIPTION                       VERSION   CAPABILITIES                ERROR
azure-kv   Notation Azure Key Vault plugin   1.0.1     [SIGNATURE_GENERATOR.RAW]   <nil>
```

Now we'll create an Azure Key Vault instance for our test and configure the signature.

```bash
AKV_NAME=mynotationtest

# Create the key vault
az keyvault create --name $AKV_NAME --resource-group $RG

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

Finally, now that we have the image signed with our certifcate from Azure Key Vault, lets set up our local environment trust policy to allow us to verify the image signature is valid locally. We'll need to download the certificate and add a local trust store.

```bash
# Download the cert from Azure Key Vault so we can verify the image locally with the AKV cert
az keyvault certificate download --name $CERT_NAME --vault-name $AKV_NAME --file $CERT_PATH

STORE_TYPE="ca"
STORE_NAME="brooklyn.io"
notation cert add --type $STORE_TYPE --store $STORE_NAME $CERT_PATH

cat <<EOF > ./trustpolicy.json
{
    "version": "1.0",
    "trustPolicies": [
        {
            "name": "brooklyn-images",
            "registryScopes": [ "$ACR_NAME.azurecr.io/nginx" ],
            "signatureVerification": {
                "level" : "strict" 
            },
            "trustStores": [ "$STORE_TYPE:$STORE_NAME" ],
            "trustedIdentities": [
                "x509.subject: $CERT_SUBJECT"
            ]
        }
    ]
}
EOF

# Import the policy and show it
notation policy import ./trustpolicy.json
notation policy show

# Test image verification
notation verify $ACR_NAME.azurecr.io/nginx@$IMAGE_SHA

# Sample success message!!!
Successfully verified signature for mynotationlab.azurecr.io/nginx@sha256:86e53c4c16a6a276b204b0fd3a8143d86547c967dc8258b3d47c3a21bb68d3c6
```

## Conclusion

You should now have some familiarity with the notation cli tool and how to use it to sign container images in a container registry with both self-signed certificates and certificates from Azure Key Vault. The next step would be to enable verification in kubernetes.

**Next: ** [Part 2 - Image Verification in AKS](./2-aks-image-verification.md)