# AKS ALM Integration

## Cluster Setup

```bash
# Set environment variables
RG=EphAKSAML
CLUSTER_NAME=amltarget
LOC=westus3
export VM_SKU="Standard_D4s_v6"
ACR_NAME=amllab${RANDOM}
AML_WORKSPACE_NAME=amllab

# Create Resource Group
az group create -g $RG -l $LOC

# Create the cluster
az aks create -g $RG \
-n $CLUSTER_NAME \
--node-vm-size $VM_SKU \
--node-count 3 \
--network-plugin azure \
--network-plugin-mode overlay \
--network-dataplane cilium \
--vnet-subnet-id $VNET_SUBNET_ID \
--enable-managed-identity \
--enable-oidc-issuer \
--enable-workload-identity \
--attach-acr $ACR_NAME

AKS_CLUSTER_ID=$(az aks show -g $RG -n $CLUSTER_NAME --query id -o tsv)

az aks get-credentials -g $RG -n $CLUSTER_NAME

# Create a certificate and secret for kubernetes ingress

kubectl create ns amllab
kubectl create ns azureml

# Create a self-signed certificate (for testing) and a Kubernetes TLS secret.
# For production use a CA-signed certificate, cert-manager, or Azure Key Vault.
HOST="amllab.crashoverride.nyc"
KEY_FILE="key.pem"
CERT_FILE="cert.pem" 

openssl req -x509 -nodes -days 365 \
-newkey rsa:2048 -keyout ${KEY_FILE} \
-out ${CERT_FILE} \
-subj "/CN=${HOST}/O=${HOST}" \
-outform PEM \
-addext "subjectAltName = DNS:${HOST}"

kubectl create secret generic amllab-ingress-tls \
--from-file=${KEY_FILE}=${KEY_FILE} --from-file=${CERT_FILE}=${CERT_FILE} \
-n azureml

az k8s-extension create \
--name amlextension \
--extension-type Microsoft.AzureML.Kubernetes \
--config enableInference=True inferenceRouterServiceType=LoadBalancer allowInsecureConnections=False InferenceRouterHA=False sslSecret=amllab-ingress-tls sslCname=amllab.crashoverride.nyc \
--cluster-type managedClusters \
--cluster-name $CLUSTER_NAME \
--resource-group $RG \
--scope cluster
```

## Deploy Inference Endpoint

```bash
az extension add -n ml
az extension update -n ml

export ENDPOINT_NAME="testamlaksendpoint"

mkdir model
cd model

cat <<"EOF" > endpoint.yaml
$schema: https://azuremlschemas.azureedge.net/latest/kubernetesOnlineEndpoint.schema.json
name: my-endpoint
compute: azureml:k8s-compute
auth_mode: Key
tags:
  tag1: endpoint-tag1-value
EOF

cat <<EOF >deployment.yaml
\$schema: https://azuremlschemas.azureedge.net/latest/kubernetesOnlineDeployment.schema.json
name: blue
type: kubernetes
endpoint_name: ${ENDPOINT_NAME}
model:
  path: ./
code_configuration:
  code: ./
  scoring_script: score.py
environment: 
  conda_file: ./conda.yaml
  image: mcr.microsoft.com/azureml/openmpi4.1.0-ubuntu22.04:latest
request_settings:
  request_timeout_ms: 3000
  max_queue_wait_ms: 3000
resources:
  requests:
    cpu: "0.1"
    memory: "0.1Gi"
  limits:
    cpu: "0.2"
    memory: "200Mi"
tags:
  tag1: deployment-tag1-value
instance_count: 1
scale_settings:
  type: default
EOF

wget https://raw.githubusercontent.com/Azure/azureml-examples/refs/heads/main/sdk/python/endpoints/online/model-1/onlinescoring/score.py

wget https://raw.githubusercontent.com/Azure/azureml-examples/refs/heads/main/sdk/python/endpoints/online/model-1/environment/conda.yaml

az ml online-endpoint create \
-g $RG \
-w $AML_WORKSPACE_NAME \
-n $ENDPOINT_NAME \
-f endpoint.yaml



```