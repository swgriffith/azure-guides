# Using AKS Automatic as an Azure ML Compute target

## Introduction

In this walk through we'll take advantage of [AKS Automatic]() to create the quickest AKS compute target for Azure ML.


## Cluster Setup

In this setup we'll assume that the cluster needs no corp network connectivity, so we'll create it in a stand along Vnet, automatically generate by the cluster creation process. We'll also leave all AKS Automatic defaults.

>*NOTE:* At the writing of this guide, AKS Automatic is still in preview, so we'll need to take some steps to enable the preview in our cli and in the Azure Subscription

```bash
# Add/Update the CLI preview extension 
az extension add --name aks-preview
az extension update --name aks-preview

# Register the feature flags
az feature register --namespace Microsoft.ContainerService --name EnableAPIServerVnetIntegrationPreview
az feature register --namespace Microsoft.ContainerService --name NRGLockdownPreview
az feature register --namespace Microsoft.ContainerService --name SafeguardsPreview
az feature register --namespace Microsoft.ContainerService --name NodeAutoProvisioningPreview
az feature register --namespace Microsoft.ContainerService --name DisableSSHPreview
az feature register --namespace Microsoft.ContainerService --name AutomaticSKUPreview

# Check the status of the feature
az feature show --namespace Microsoft.ContainerService --name AutomaticSKUPreview

# Update the Container Service feature
az provider register --namespace Microsoft.ContainerService
```

```bash
# Set Variables
RG=AzureML-AKSAutomatic
LOC=westus3
CLUSTER_NAME=aksautomatic

# Create the resource group
az group create -n $RG -l $LOC

# Create the AKS Automatic Cluster
az aks create \
--resource-group $RG \
--name $CLUSTER_NAME \
--sku automatic

# Get the cluster ID for later
CLUSTER_ID=$(az aks show -g $RG -n $CLUSTER_NAME --query id -o tsv)

# Get the the cluster credentials
az aks get-credentials -g $RG -n $CLUSTER_NAME

# Convert the kubeconfig for AAD Auth using kubelogin
kubelogin convert-kubeconfig -l azurecli
```

Great! How we have a running AKS cluster configured using AKS Automatic. Feel free to browse around via kubectl and the Azure Portal to see the cluster configuration.


## Create the Azure ML Instance and Attach AKS

First, we need to create the Azure ML Workspace.

```bash
# Make sure we have the Azure ML CLI Extension
az extension add -n ml

# Set the workspace name
AZUREML_WORKSPACE_NAME=aksazureml
AZUREML_KUBE_NAMESPACE=azuremllab

# Create the Azure ML Workspace
az ml workspace create -n $AZUREML_WORKSPACE_NAME -g $RG

# Install the extension on the AKS Cluster
az k8s-extension create \
--name aksazureml \
--extension-type Microsoft.AzureML.Kubernetes \
--config enableTraining=True enableInference=True inferenceRouterServiceType=LoadBalancer allowInsecureConnections=True InferenceRouterHA=False \
--cluster-type managedClusters \
--cluster-name $CLUSTER_NAME \
--resource-group $RG \
--scope cluster

# Create the target namespace
kubectl create ns $AZUREML_KUBE_NAMESPACE

# Attach the AKS Compute Target
az ml compute attach \
--resource-group $RG \
--workspace-name $AZUREML_WORKSPACE_NAME \
--type Kubernetes \
--name aks-compute \
--resource-id $CLUSTER_ID \
--identity-type SystemAssigned \
--namespace $AZUREML_KUBE_NAMESPACE \
--no-wait
```

