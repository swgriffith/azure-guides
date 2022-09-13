# Setting up AKS with dual public and private API server Addresses

## Setup

### Create the network

```bash
# Set Variables
RG=EphAPIServerVnetInt
LOC=eastus2

# Create Resource Group
az group create -n $RG -l $LOC

# Create Vnet
az network vnet create \
-g $RG \
-n aksvnet \
--address-prefix 10.40.0.0/16 \
--subnet-name aks-worker-subnet --subnet-prefix 10.40.0.0/24

# Create the API Server Subnet
az network vnet subnet create \
-g $RG \
--vnet-name aksvnet \
-n aks-apiserver-subnet \
--delegations Microsoft.ContainerService/managedClusters \
--address-prefixes 10.40.1.0/24

# Get the resource IDs
WORKER_SUBNET_ID=$(az network vnet show -g $RG -n aksvnet -o tsv --query "subnets[?name=='aks-worker-subnet'].id")
APISERVER_SUBNET_ID=$(az network vnet show -g $RG -n aksvnet -o tsv --query "subnets[?name=='aks-apiserver-subnet'].id")
```

### Enable Preview

```bash
# Install the aks-preview extension
az extension add --name aks-preview

# Update the extension to make sure you have the latest version installed
az extension update --name aks-preview

# Register for the preview
az feature register --namespace "Microsoft.ContainerService" --name "EnableAPIServerVnetIntegrationPreview"
# Check registration status
az feature list -o table --query "[?contains(name, 'Microsoft.ContainerService/EnableAPIServerVnetIntegrationPreview')].{Name:name,State:properties.state}"

az provider register --namespace Microsoft.ContainerService
```

### Create the User Assigned Managed Identity

System assigned managed identity is not supported

```bash
# Create the identity
az identity create -n aksclusterident -g $RG -l $LOC

IDENT_CLIENT_ID=$(az identity show -n aksclusterident -g $RG -o tsv --query clientId)
IDENT_RESOURCE_ID=$(az identity show -n aksclusterident -g $RG -o tsv --query id)

# Assign Network Contributor to the API server subnet
az role assignment create --scope $APISERVER_SUBNET_ID \
--role "Network Contributor" \
--assignee $IDENT_CLIENT_ID

# Assign Network Contributor to the cluster subnet
az role assignment create --scope $WORKER_SUBNET_ID \
--role "Network Contributor" \
--assignee $IDENT_CLIENT_ID
```

### Create the cluster

```bash
# Set Variables
CLUSTER_NAME=democluster

az aks create \
-g $RG \
-n $CLUSTER_NAME \
-l $LOC \
--enable-apiserver-vnet-integration \
--vnet-subnet-id $WORKER_SUBNET_ID \
--apiserver-subnet-id $APISERVER_SUBNET_ID \
--assign-identity $IDENT_RESOURCE_ID

# Get Cluster Admin Credentials
az aks get-credentials -g $RG -n $CLUSTER_NAME
```

### Get the API Server Private IP

```bash
# Get the Managed Cluster Resource Group
NODE_RG=$(az aks show -g $RG -n $CLUSTER_NAME -o tsv --query nodeResourceGroup)

# Get the Private IP of the API Server Load Balancer Front End
API_PRIVATE_IP=$(az network lb frontend-ip show -g $NODE_RG --lb-name kube-apiserver -n kube-apiserver-frontend -o tsv --query privateIpAddress)

# Get the API Server FQDN
API_FQDN=$(az aks show -g $RG -n $CLUSTER_NAME -o tsv --query fqdn)

# Add the above to your /etc/hosts, or add an A-Record
```