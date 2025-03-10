# AKS ALM Integration

## Cluster Setup

```bash
# Set environment variables
RG=EphAKSAMLLab
CLUSTER_NAME=amltarget
LOC=westus3
ACR_NAME=amllab${RANDOM}
AML_WORKSPACE_NAME=amllab

# Create Resource Group
az group create -g $RG -l $LOC

# Create the cluster
az aks create -g $RG -n $CLUSTER_NAME

AKS_CLUSTER_ID=$(az aks show -g $RG -n $CLUSTER_NAME --query id -o tsv)

az aks get-credentials -g $RG -n $CLUSTER_NAME

kubectl create ns amltest

az k8s-extension create \
--name amlextension \
--extension-type Microsoft.AzureML.Kubernetes \
--config enableTraining=True enableInference=True inferenceRouterServiceType=LoadBalancer allowInsecureConnections=True InferenceRouterHA=False \
--cluster-type managedClusters \
--cluster-name $CLUSTER_NAME \
--resource-group $RG \
--scope cluster

az k8s-extension show \
--name amlextension \
--cluster-type connectedClusters \
--cluster-name $CLUSTER_NAME \
--resource-group $RG


az ml workspace create -n $AML_WORKSPACE_NAME -g $RG

az ml compute attach \
--resource-group $RG \
--workspace-name $AML_WORKSPACE_NAME \
--type Kubernetes \
--name k8s-compute \
--resource-id "${AKS_CLUSTER_ID}" \
--identity-type SystemAssigned \
--namespace amltest
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

az ml online-deployment create \
-g $RG \
-w $AML_WORKSPACE_NAME \
-n blue \
--endpoint $ENDPOINT_NAME \
-f deployment.yaml
```