# Image Signing and Verification with Cosign

# Introduction

When it comes to container image signing and verification there are two main Open Source projects in use today. [SigStore](https://docs.sigstore.dev/) and [Notary v2](https://github.com/notaryproject). There are a ton of blog posts and videos out there that give a great comparison of the two, so I wont dive into that here, however I will demonstrate the following two key differences:

1. Sigstore was not designed to be specific to container image signing. You can use the tool chain in SigStore to sign blobs as well, which enables you to move the signing capability closer to the developer if you wish.
2. Sigstore does not require you to provide a key to sign. Through the [Fulcio](https://docs.sigstore.dev/certificate_authority/overview/) Certificate Authority and [Rekor](https://docs.sigstore.dev/logging/overview/) as the signing ledger, you're able to keylessly sign your content.

## Getting Started with Cosign

Both Rekor and Fulcio are provided as a hosted solution by SigStore, so you dont need to install them, although you could run your own instances if you wish. All we need to install is the [Cosign](https://docs.sigstore.dev/signing/quickstart/) cli tool, which we will use for our image signing and local verification.

### Installation

[Installing Cosign](https://docs.sigstore.dev/system_config/installation/)

### Cosign isnt just for containers!

As noted above, SigStore is not specific to container image signing, which is unique compared to Notary v2. Notary v2 is more purpose built for container image signing and verification.

As an example, let's generate and sign a simple text file and then verify that file. When we run 'cosign sign-blob' a new browser window will pop up asking to chose an OIDC issuer (Google, Microsoft or GitHub) to verify our ownership of an identity (i.e. my GitHub identity). It will then use that issuer and your identity to call Fulcio to create the signing certificate, issue a record to Rekor and then output the signing bundle which can be used to verify the file. 

>*NOTE:* Having Rekor to act as the ledger means that the certificates issued by Fulcio can be short lived, as they really only need to be valid for the time it takes to get the Rekor record created. That means that we dont need to store the certificate ourselves, and can just rely on Rekor to validate the signature validity.

```bash
# Create a test file
cat << EOF >> testfile.txt
I need to get signed
EOF

# Use sign-blob to generage a signature record in Rekor and output the cosign bundle
# NOTE: This will pop a browser window where you choose your OIDC Issuer
# You'll need to know which issuer you use to later verify the blob
cosign sign-blob testfile.txt  --bundle cosign.bundle

# You can inspect the bundle. I'm piping to jq for readability
cat cosign.bundle|jq

# Verify the blob, passing in the bundle, certificate identity and the OIDC issuer you used.
cosign verify-blob testfile.txt --bundle cosign.bundle --certificate-identity stgriffi@microsoft.com --certificate-oidc-issuer https://github.com/login/oauth

# Sample output
Verified OK

# Edit the file
echo "pwned">>testfile.txt

# Try to verify the file again
cosign verify-blob testfile.txt --bundle cosign.bundle --certificate-identity stgriffi@microsoft.com --certificate-oidc-issuer https://github.com/login/oauth

# Sample output
Error: error verifying bundle: matching bundle to payload.......
```

Here are the other OIDC Issuer URLS:
- Github: https://github.com/login/oauth
- Microsoft: https://login.microsoftonline.com
- Google: https://accounts.google.com

### Create Lab Environment

We'll be using Azure Container Registry and eventually AKS to sign and verify images, so lets set that up.

```bash
# Set Variables
RG=CosignLab
LOC=eastus
ACR_NAME=cosignlab$RANDOM
CLUSTER_NAME=cosignlab

# Create the resource group
az group create -n $RG -l $LOC

# Create the Azure Container Registry
az acr create -g $RG -n $ACR_NAME --sku premium

# Create the AKS Cluster and attach the ACR
az aks create -g $RG -n $CLUSTER_NAME --attach-acr $ACR_NAME

# Get the cluster credentials
az aks get-credentials -g $RG -n $CLUSTER_NAME

```

### Keyless Container Image Signing

Now that we have a lab environment and a better idea of how SigStore works, lets sign a container image. These steps are based on the cosign project [getting started](https://github.com/sigstore/cosign?tab=readme-ov-file#quick-start) guide.

```bash
# Create a test Dockerfile
# Using a SHA to be extra specific about the image we want
cat << EOF >>Dockerfile
FROM nginx@sha256:a484819eb60211f5299034ac80f6a681b06f89e65866ce91f356ed7c72af059c
RUN echo "My image">/usr/share/nginx/html/index.html
EOF

# Build image locally
docker build -t mytestimage .

# Keyless sign the new image
# NOTE: This fails because you cant to sign a local build image
cosign sign mytestimage

# ACR build the image
az acr build --registry $ACR_NAME --image mytestimage:v1 .

# Login to ACR so that cosign can pull
az acr login -n $ACR_NAME

# Sign the image
# Note: This will bring up a browser to have you log in to
# a supported identity provider (ex. GitHub, Google, Microsoft)
cosign sign $ACR_NAME.azurecr.io/mytestimage:v1
```

Three things to note from this keyless signing process:

1. For keyless siging you will need to login to a supported identity provider and share your basic account info (ex. Name and Email Address) 
1. You are informed that 'if your submission includes personal data associated with this signed artifact, it will be part of an immutable record'
1. For a private registry your registry name will be recorded in the Rekor transparency log

If the above requirements are a concern for you, you can look at running your own instances of Fulcio and Rekor to perform keyless signing, or you can sign with your own generaged key.

### Verify Signature

To keyless verify the signature you'll need two parameters. 

1. The email address used when you selected the provider (i.e. Github, Google or Microsoft email)
2. The OIDC issuer url
    - Github: https://github.com/login/oauth
    - Microsoft: https://login.microsoftonline.com
    - Google: https://accounts.google.com

```bash
# Email Address
IDENTITY=stgriffi@microsoft.com
OIDC_ISSUER_URL=https://github.com/login/oauth

cosign verify --certificate-identity=$IDENTITY  --certificate-oidc-issuer=$OIDC_ISSUER_URL $ACR_NAME.azurecr.io/mytestimage:v1

# For pretty output, pipe to jq
cosign verify --certificate-identity=$IDENTITY  --certificate-oidc-issuer=$OIDC_ISSUER_URL $ACR_NAME.azurecr.io/mytestimage|jq
```

### Using Rekor

As mentioned previously, Rekor is the transparency log for Sigstore image signing, so you can just hit it via curl or via their CLI to see the signing transactions for your image. 

```bash
# Install - brew
brew install rekor-cli

# Get the logIndex so we can look up the record in Rekor
# This value is buried in the metadata, so you'll have to copy it out
az acr manifest list -r $ACR_NAME -n mytestimage -o json|grep logIndex

# Set the log index
#LOG_INDEX=95412912
LOG_INDEX=<Log Index>

# Read the signature log from Rekor's public endpoint
rekor-cli get --rekor_server https://rekor.sigstore.dev --log-index $LOG_INDEX --format json
```

### Install Kyverno for Image Verification

Now that we have a signed image in our Azure Container Registry, lets implement image signature verification in our AKS cluster. There are a few ways to do this, but [Kyverno](https://kyverno.io/) has a very simple CRD based approach, so we'll use that here. 

Let's install Kyverno:

```bash
helm repo add kyverno https://kyverno.github.io/kyverno/

helm repo update

helm install kyverno kyverno/kyverno -n kyverno --create-namespace 


helm install kyverno-policies kyverno/kyverno-policies -n kyverno
```

Now we'll create an image verification policy:

```bash
# Set variables
# NOTE: You should still have the ACR_NAME, IDENTITY and OIDC_ISSUER_URL values set from above.
IMAGE_NAME=mytestimage

cat << EOF > check-signed-image.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: check-image-keyless
spec:
  validationFailureAction: Enforce
  webhookTimeoutSeconds: 30
  rules:
    - name: check-image-keyless
      match:
        any:
        - resources:
            kinds:
              - Pod
      verifyImages:
      - imageReferences:
        - "$ACR_NAME.azurecr.io/$IMAGE_NAME*"
        attestors:
        - entries:
          - keyless:
              subject: "$IDENTITY"
              issuer: "$OIDC_ISSUER_URL"
              rekor:
                url: https://rekor.sigstore.dev
EOF
```

For this test, lets import another version of the nginx pod that has not been signed, and then we'll test both pods.

```bash
# Import nginx image with a 'fail' tag
 az acr import --name $ACR_NAME --source docker.io/library/nginx --image mytestimage:fail

 # Try to run the fail pod
kubectl run fail-pod --image=$ACR_NAME.azurecr.io/mytestimage:fail

# Sample Output
Error from server: admission webhook "mutate.kyverno.svc-fail" denied the request: 
resource Pod/default/fail-pod was blocked due to the following policies 
check-image-keyless:
  check-image-keyless: 'failed to verify image cosignlab16059.azurecr.io/mytestimage:fail:
    .attestors[0].entries[0].keyless: no signatures found'

# Try to deploy our signed image
kubectl run myapp --image=$ACR_NAME.azurecr.io/mytestimage:v1

# Sample Output
pod/myapp created
```

## Conclusion

In this walk-through we saw how Sigstore enabled keyless signign of blobs and container images via the Fulcio Certificate Authority and the Rekor transparency log. We also showed how Kyverno policy engine can be used to verify those images when deploying workloads to a Kubernetes cluster.