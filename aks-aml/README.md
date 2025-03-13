# AKS ALM Integration

## Azure CLI and kubectl Setup

```bash
# This guides uses commands from two Azure CLI extensions: k8s-extension and ml

az extension add --upgrade -n ml
az extension add --upgrade -n k8s-extension

# It also assumes you have kubectl installed. If not, you can run:
az aks install-cli
```

## AKS Cluster and Azure ML Workspace Setup

```bash
# Set environment variables
RG=EphAKSAMLLab
CLUSTER_NAME=amltarget
LOC=westus3
AML_WORKSPACE_NAME=amllab
CLUSTER_AML_NAMESPACE=amltest

# Create Resource Group
az group create -g $RG -l $LOC

# Create the cluster
az aks create -g $RG -n $CLUSTER_NAME

AKS_CLUSTER_ID=$(az aks show -g $RG -n $CLUSTER_NAME --query id -o tsv)

az aks get-credentials -g $RG -n $CLUSTER_NAME

kubectl create ns $CLUSTER_AML_NAMESPACE

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
--cluster-type managedClusters \
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
--namespace $CLUSTER_AML_NAMESPACE
```

## Deploy Inference Endpoint

```bash
# Setup environment

export ENDPOINT_NAME="testamlaksendpoint"
export DEPLOYMENT_NAME="blue"
export MODEL_NAME="sklearn-regression"

# Prepare files to be used by the Azure ML Online Deployment.
# Be sure all files created (endpoint.yaml, deployment.yaml) or
# downloaded (sklearn_regression_model.pkl, score.py, conda.yaml)
# are in the same directory. Run all `az ml online-endpoint create`
# and `az ml online-deployment create` commands from that directory
# as well since they have relative path dependencies.

# Grant the identity running the CLI commands Storage Blob Data Contributor
# on the Azure ML workspace's storage account.

az role assignment create \
--role "Storage Blob Data Contributor" \
--assignee-object-id "$(az ad signed-in-user show --query id -o tsv)" \
--assignee-principal-type "User" \
--scope "$(az ml workspace show -n $AML_WORKSPACE_NAME -g $RG --query storage_account -o tsv)"

# Create local directory for all needed files

mkdir model
cd model

# Create Azure ML Online Endpoint specification file

cat <<EOF > endpoint.yaml
\$schema: https://azuremlschemas.azureedge.net/latest/kubernetesOnlineEndpoint.schema.json
name: ${ENDPOINT_NAME}
compute: azureml:k8s-compute
auth_mode: Key
tags:
  modelName: ${MODEL_NAME}
EOF

# Create Azure ML Online Deployment specification file

cat <<EOF >deployment.yaml
\$schema: https://azuremlschemas.azureedge.net/latest/kubernetesOnlineDeployment.schema.json
name: ${DEPLOYMENT_NAME}
type: kubernetes
endpoint_name: ${ENDPOINT_NAME}
model:
  path: ./sklearn_regression_model.pkl
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
  endpointName: ${ENDPOINT_NAME}
  modelName: ${MODEL_NAME}
instance_count: 1
scale_settings:
  type: default
EOF

# Download required model files

wget https://raw.githubusercontent.com/Azure/azureml-examples/refs/heads/main/sdk/python/endpoints/online/model-1/model/sklearn_regression_model.pkl

wget https://raw.githubusercontent.com/Azure/azureml-examples/refs/heads/main/sdk/python/endpoints/online/model-1/onlinescoring/score.py

wget https://raw.githubusercontent.com/Azure/azureml-examples/refs/heads/main/sdk/python/endpoints/online/model-1/environment/conda.yaml


# Create the Azure ML Online Endpoint

az ml online-endpoint create \
-g $RG \
-w $AML_WORKSPACE_NAME \
-n $ENDPOINT_NAME \
-f endpoint.yaml

# Create the Azure ML Online Deployment and send all traffic to it

az ml online-deployment create \
-g $RG \
-w $AML_WORKSPACE_NAME \
-n $DEPLOYMENT_NAME \
--endpoint $ENDPOINT_NAME \
--all-traffic \
-f deployment.yaml

```

## Test the Inference Endpoint

```bash
# Get the key required for the Authorization header

SCORING_ACCESS_KEY=$(kubectl get onlineendpoint $ENDPOINT_NAME -n $CLUSTER_AML_NAMESPACE -o jsonpath={.spec.authKeys.primaryKey})

# Get the endpoint URL for the request

SCORING_ENDPOINT_URL=$(kubectl get onlineendpoint $ENDPOINT_NAME -n $CLUSTER_AML_NAMESPACE -o jsonpath={.status.scoringUri})

# Post the test data to test the inference endpoint

curl -X POST -H "Content-Type: application/json" \
-H "Authorization: Bearer $SCORING_ACCESS_KEY" \
--data "$(curl -s https://raw.githubusercontent.com/Azure/azureml-examples/refs/heads/main/sdk/python/endpoints/online/model-1/sample-request.json)" \
--url $SCORING_ENDPOINT_URL
```