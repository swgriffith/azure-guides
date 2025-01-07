# AKS Network Isolated Cluster

## Feature Registration

```bash
# Registery/Update the Azure CLI AKS Preview Extension
az extension add --name aks-preview
az extension update --name aks-preview

# Register for the Preview
az feature register --namespace Microsoft.ContainerService --name NetworkIsolatedClusterPreview

# Check feature registration status
az feature show --namespace Microsoft.ContainerService --name NetworkIsolatedClusterPreview
```

## Environment Prep

```bash
# Set environment variables
# Resource Group
RG=EphAKSNetworkIsolated
# Azure Region
LOC=eastus2
# AKS Cluster Name
CLUSTER_NAME=aksisolated
# Unique Azure Container Registry Name
ACR_NAME=aksisolate$RANDOM
# Virtual Network Name
VNET_NAME=aks-isolated-vnet
# Subnet Name
AKS_SUBNET_NAME=aks-subnet
# ACR Subnet Name
ACR_SUBNET_NAME=acr-subnet

# Create the resource group
az group create \
--name $RG \
--location $LOC

# Create the Virtual Network
az network vnet create  \
--resource-group $RG \
--name $VNET_NAME \
--address-prefixes 10.100.0.0/16

# Create the cluster subnet blocking outbound connectivity
az network vnet subnet create \
--name $AKS_SUBNET_NAME \
--vnet-name $VNET_NAME \
--resource-group $RG \
--address-prefixes 10.100.0.0/24 \
--default-outbound-access false

# Get the aks subnet id
SUBNET_ID=$(az network vnet subnet show \
--name $AKS_SUBNET_NAME \
--vnet-name $VNET_NAME \
--resource-group $RG \
--query 'id' \
--output tsv)

# Create the ACR subnet
az network vnet subnet create \
--name $ACR_SUBNET_NAME \
--vnet-name $VNET_NAME \
--resource-group $RG \
--address-prefixes 10.100.1.0/24 \
--private-endpoint-network-policies Disabled

# Create the ACR
az acr create \
--resource-group $RG \
--name $ACR_NAME \
--sku Premium \
--public-network-enabled false

# Disable Anonymous pull
az acr update \
--resource-group $RG \
--name $ACR_NAME \
--anonymous-pull-enabled true

# Get the ACR ID
ACR_ID=$(az acr show \
--name $ACR_NAME \
-g $RG  \
--query 'id' \
--output tsv)

# Enable the MCR pull-through cache
az acr cache create \
-n acr-cache-rule \
-r $ACR_NAME \
-g $RG \
--source-repo "mcr.microsoft.com/*" \
--target-repo "*"

# Create the ACR private endpoint
az network private-endpoint create \
--name myPrivateEndpoint \
--resource-group $RG \
--vnet-name $VNET_NAME \
--subnet $ACR_SUBNET_NAME \
--private-connection-resource-id $ACR_ID \
--group-id registry \
--connection-name myConnection

# Get the ACR Network Info for the Private Zone Creation
NETWORK_INTERFACE_ID=$(az network private-endpoint show \
--name myPrivateEndpoint \
--resource-group $RG \
--query 'networkInterfaces[0].id' \
--output tsv)

REGISTRY_PRIVATE_IP=$(az network nic show \
--ids $NETWORK_INTERFACE_ID \
--query "ipConfigurations[?privateLinkConnectionProperties.requiredMemberName=='registry'].privateIPAddress" \
--output tsv)

DATA_ENDPOINT_PRIVATE_IP=$(az network nic show \
--ids $NETWORK_INTERFACE_ID \
--query "ipConfigurations[?privateLinkConnectionProperties.requiredMemberName=='registry_data_$LOC'].privateIPAddress" \
--output tsv)

# Create the ACR Private Zone
az network private-dns zone create \
--resource-group $RG \
--name "privatelink.azurecr.io"

# Link the private zone to the ACR Vnet
az network private-dns link vnet create \
--resource-group $RG \
--zone-name "privatelink.azurecr.io" \
--name MyDNSLink \
--virtual-network $VNET_NAME \
--registration-enabled false

# Create the A-Records for the ACR IP
az network private-dns record-set a create \
--name $ACR_NAME \
--zone-name "privatelink.azurecr.io" \
--resource-group $RG

az network private-dns record-set a add-record \
--record-set-name $ACR_NAME \
--zone-name "privatelink.azurecr.io" \
--resource-group $RG \
--ipv4-address ${REGISTRY_PRIVATE_IP}

az network private-dns record-set a create \
--name $ACR_NAME.$LOC.data \
--zone-name "privatelink.azurecr.io" \
--resource-group $RG

az network private-dns record-set a add-record \
--record-set-name $ACR_NAME.$LOC.data \
--zone-name "privatelink.azurecr.io" \
--resource-group $RG \
--ipv4-address ${DATA_ENDPOINT_PRIVATE_IP}

# Set the Cluster and Kubelet Identity Names
CLUSTER_IDENTITY_NAME=${CLUSTER_NAME}-identity
KUBELET_IDENTITY_NAME=${CLUSTER_NAME}-kubelet-identity

# Create the cluster Kubelet and Cluster Identities
az identity create --name ${CLUSTER_IDENTITY_NAME} --resource-group $RG

CLUSTER_IDENTITY_RESOURCE_ID=$(az identity show \
--name ${CLUSTER_IDENTITY_NAME} \
--resource-group $RG \
--query 'id' \
-o tsv)

CLUSTER_IDENTITY_PRINCIPAL_ID=$(az identity show \
--name ${CLUSTER_IDENTITY_NAME} \
--resource-group $RG \
--query 'principalId' \
-o tsv)

az identity create --name ${KUBELET_IDENTITY_NAME} --resource-group $RG

KUBELET_IDENTITY_RESOURCE_ID=$(az identity show \
--name ${KUBELET_IDENTITY_NAME} \
--resource-group $RG \
--query 'id' \
-o tsv)

KUBELET_IDENTITY_PRINCIPAL_ID=$(az identity show \
--name ${KUBELET_IDENTITY_NAME} \
--resource-group $RG \
--query 'principalId' \
-o tsv)

# Grant ACRPull rights for the kubelet identity
az role assignment create \
--role AcrPull \
--scope ${ACR_ID} \
--assignee-object-id ${KUBELET_IDENTITY_PRINCIPAL_ID} \
--assignee-principal-type ServicePrincipal

```

## Cluster Creation - API Server Vnet Integration Mode

```bash
# Create the API Server subnet and get it's resource id
APISERVER_SUBNET_NAME=aks-apiserver-subnet

az network vnet subnet create \
--name ${APISERVER_SUBNET_NAME} \
--vnet-name ${VNET_NAME} \
--resource-group $RG \
--address-prefixes 10.100.2.0/24

export APISERVER_SUBNET_ID=$(az network vnet subnet show \
--resource-group $RG \
--vnet-name ${VNET_NAME} \
--name ${APISERVER_SUBNET_NAME} \
--query id \
-o tsv)

# Grate the cluster identity network contributor rights on the API Server subnet
az role assignment create \
--scope ${APISERVER_SUBNET_ID} \
--role "Network Contributor" \
--assignee-object-id ${CLUSTER_IDENTITY_PRINCIPAL_ID} \
--assignee-principal-type ServicePrincipal
```

Create the cluster.

```bash
az aks create \
--resource-group $RG \
--name $CLUSTER_NAME \
--vnet-subnet-id ${SUBNET_ID} \
--assign-identity ${CLUSTER_IDENTITY_RESOURCE_ID} \
--assign-kubelet-identity ${KUBELET_IDENTITY_RESOURCE_ID} \
--bootstrap-artifact-source Cache \
--bootstrap-container-registry-resource-id ${ACR_ID} \
--outbound-type none \
--network-plugin azure \
--enable-apiserver-vnet-integration \
--apiserver-subnet-id ${APISERVER_SUBNET_ID}
```

## Testing

```bash
JUMP_VM_NAME="jumpvm"
VM_USERNAME=griffith

az network vnet subnet create \
--name jump-subnet \
--vnet-name ${VNET_NAME} \
--resource-group $RG \
--address-prefixes 10.100.3.0/24

az vm create \
--resource-group $RG \
--name $JUMP_VM_NAME \
--image Ubuntu2204 \
--admin-username $VM_USERNAME \
--assign-identity \
--generate-ssh-keys \
--vnet-name ${VNET_NAME} \
--subnet jump-subnet

JUMP_IP=$(az vm list-ip-addresses -g $RG -n $JUMP_VM_NAME -o tsv --query "[].virtualMachine.network.publicIpAddresses[0].ipAddress")

# Get the cluster credentials and copy to the jump box
az aks get-credentials -g $RG -n $CLUSTER_NAME

ssh ${VM_USERNAME}@${JUMP_IP} "mkdir /home/${VM_USERNAME}/.kube"
scp -r ~/.kube/config ${VM_USERNAME}@${JUMP_IP}:/home/${VM_USERNAME}/.kube/config

# Connect to the jump box
ssh ${VM_USERNAME}@${JUMP_IP}

# Install kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# Test connectivity
kubectl get nodes

# Deploy a test pod with an http endpoint
kubectl run nginx --image=mcr.microsoft.com/azurelinux/base/nginx:1.25 --port 80

# Start and jump into a busybox pod
kubectl run busybox --image=mcr.microsoft.com/azurelinux/busybox:1.36 --rm -it -- /bin/sh
```