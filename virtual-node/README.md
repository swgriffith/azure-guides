# AKS Virtual Node

```bash
RG=EphVirtualNode
LOC=eastus
CLUSTER_NAME=virtualnode

# Create a resource group
az group create -n $RG -l $LOC

# Get the resource group id
RG_ID=$(az group show -n $RG -o tsv --query id)

# Create a Vnet
az network vnet create \
--resource-group $RG \
--name virtualnodecluster \
--address-prefixes 10.100.0.0/16 \
--subnet-name aks \
--subnet-prefix 10.100.0.0/24

# Add virtual node subnet
az network vnet subnet create \
--resource-group $RG \
--vnet-name virtualnodecluster \
--name virtualnodes \
--address-prefixes 10.100.1.0/24

# Get the Vnet/Subnet ID
VNET_SUBNET_ID=$(az network vnet subnet show -g $RG --vnet-name virtualnodecluster -n aks -o tsv --query id)

# Create Cluster Managed Identity
az identity create -g $RG -n clusteridentity

# Get the cluster identity client id
CLUSTER_IDENT_ID=$(az identity show -g $RG -n clusteridentity -o tsv --query id)
CLUSTER_IDENT_PRINCIPAL_ID=$(az identity show -g $RG -n clusteridentity -o tsv --query principalId)

# Give the cluster identity Contributor on the resource group
az role assignment create \
--assignee $CLUSTER_IDENT_PRINCIPAL_ID \
--role "Contributor" \
--scope $RG_ID

# Create the cluster
az aks create -g $RG -n $CLUSTER_NAME \
--enable-managed-identity \
--assign-identity $CLUSTER_IDENT_ID \
--network-plugin azure \
--network-plugin-mode overlay \
--vnet-subnet-id $VNET_SUBNET_ID \
--enable-addons virtual-node \
--aci-subnet-name virtualnodes

# Get the node resource group
AKS_NODE_RG=$(az aks show -g $RG -n $CLUSTER_NAME -o tsv --query nodeResourceGroup)
AKS_NODE_RG_ID=$(az group show -n $AKS_NODE_RG -o tsv --query id)

az role assignment create \
--assignee $CLUSTER_IDENT_PRINCIPAL_ID \
--role "Contributor" \
--scope $AKS_NODE_RG_ID

# Get the cluster credentials
az aks get-credentials -g $RG -n $CLUSTER_NAME

# Deploy the test app
kubectl apply -f ./manifests
```