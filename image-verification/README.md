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

az aks create -g $RG -n $CLUSTER_NAME \
--enable-addons azure-policy \
--enable-oidc-issuer \
--enable-workload-identity

az aks get-credentials -g $RG -n $CLUSTER_NAME

az acr create -g $RG -n $ACR_NAME --sku Standard

az aks update -g $RG -n $CLUSTER_NAME --attach-acr $ACR_NAME


SCOPE="/subscriptions/${SUBSCRIPTION}/resourceGroups/${RG}"

az policy assignment create --name 'deploy-trustedimages' --policy-set-definition 'af28bf8b-c669-4dd3-9137-1e68fdc61bd6' --display-name 'Audit deployment with unsigned container images' --scope ${SCOPE} --mi-system-assigned --role Contributor --identity-scope ${SCOPE} --location ${LOC}

MC_RESOURCE_GROUP=$(az aks show -g $RG -n $CLUSTER_NAME -o tsv --query nodeResourceGroup)
IDENTITY_NAME="azurepolicy-${CLUSTER_NAME}"

export IDENTITY_OBJECT_ID="$(az identity show --name "azurepolicy-${CLUSTER_NAME}" --resource-group "${MC_RESOURCE_GROUP}" --query 'principalId' -otsv)"
export IDENTITY_CLIENT_ID=$(az identity show --name "azurepolicy-${CLUSTER_NAME}" --resource-group ${MC_RESOURCE_GROUP} --query 'clientId' -o tsv)


# Grant the ratify identity acr pull rights
az role assignment create \
--assignee-object-id ${IDENTITY_OBJECT_ID} \
--role acrpull \
--scope subscriptions/${SUBSCRIPTION}/resourceGroups/${RG}/providers/Microsoft.ContainerRegistry/registries/${ACR_NAME}

# Get the OIDC Issuer URL
export AKS_OIDC_ISSUER="$(az aks show -n ${CLUSTER_NAME} -g ${RG} --query "oidcIssuerProfile.issuerUrl" -o tsv)"

# Federate the managed identity to the service account used by ratify
az identity federated-credential create \
--name ratify-federated-credential \
--identity-name "${IDENTITY_NAME}" \
--resource-group "${MC_RESOURCE_GROUP}" \
--issuer "${AKS_OIDC_ISSUER}" \
--subject system:serviceaccount:gatekeeper-system:ratify-admin

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

az keyvault set-policy --name ${AKV_NAME} \
--secret-permissions get \
--object-id ${IDENTITY_OBJECT_ID}

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

# Import the image
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


### Apply the policy


```bash
cat << EOF > ratify-policy-template.yaml
apiVersion: templates.gatekeeper.sh/v1beta1
kind: ConstraintTemplate
metadata:
  name: ratifyverification
spec:
  crd:
    spec:
      names:
        kind: RatifyVerification
  targets:
    - target: admission.k8s.gatekeeper.sh
      rego: |
        package ratifyverification
        
        # Get data from Ratify
        remote_data := response {
          images := [img | img = input.review.object.spec.containers[_].image]
          response := external_data({"provider": "ratify-provider", "keys": images})
        }

        # Base Gatekeeper violation
        violation[{"msg": msg}] {
          general_violation[{"result": msg}]
        }
        
        # Check if there are any system errors
        general_violation[{"result": result}] {
          err := remote_data.system_error
          err != ""
          result := sprintf("System error calling external data provider: %s", [err])
        }
        
        # Check if there are errors for any of the images
        general_violation[{"result": result}] {
          count(remote_data.errors) > 0
          result := sprintf("Error validating one or more images: %s", remote_data.errors)
        }
        
        # Check if the success criteria is true
        general_violation[{"result": result}] {
          subject_validation := remote_data.responses[_]
          subject_validation[1].isSuccess == false
          result := sprintf("Subject failed verification: %s", [subject_validation[0]])
        }
EOF

cat << EOF > ratify-policy-constraint.yaml
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: RatifyVerification
metadata:
  name: ratify-constraint
spec:
  enforcementAction: deny
  match:
    kinds:
      - apiGroups: [""]
        kinds: ["Pod"]
    namespaces: ["default"]
EOF

POLICY_TEMPLATE=$(cat ratify-policy-template.yaml|base64)
POLICY_CONSTRAINT=$(cat ratify-policy-constraint.yaml|base64)

cat << EOF > policy-definition.json
{
    "properties": {
        "displayName": "Image Verification",
        "policyType": "Custom",
        "mode": "Microsoft.Kubernetes.Data",
        "description": "Only allow signed images",
        "metadata": {
            "version": "1.0.0",
            "category": "Kubernetes"
        },
        "parameters": {
            "effect": {
                "type": "String",
                "metadata": {
                    "displayName": "Effect",
                    "description": "Enable or disable the execution of the policy"
                },
                "allowedValues": [
                    "audit",
                    "deny",
                    "disabled"
                ],
                "defaultValue": "audit"
            },
            "excludedNamespaces": {
                "type": "Array",
                "metadata": {
                    "displayName": "Namespace exclusions",
                    "description": "List of Kubernetes namespaces to exclude from policy evaluation. Providing a value for this parameter is optional."
                },
                "defaultValue": [
                    "kube-system",
                    "gatekeeper-system",
                    "azure-arc"
                ]
            }
        },
        "policyRule": {
            "if": {
                "field": "type",
                "in": [
                    "AKS Engine",
                    "Microsoft.Kubernetes/connectedClusters",
                    "Microsoft.ContainerService/managedClusters"
                ]
            },
            "then": {
                "effect": "[parameters('effect')]",
                "details": {
                    "templateInfo": {
                        "sourceType": "Base64Encoded",
                        "content": "${POLICY_TEMPLATE}"
                    },
                    "excludedNamespaces": "[parameters('excludedNamespaces')]",
                    "values": {
                    },
                    "apiGroups": [
                        "extensions",
                        "networking.k8s.io"
                    ],
                    "kinds": [
                        "Pod"
                    ]
                }
            }
        }
    }
}
EOF
```