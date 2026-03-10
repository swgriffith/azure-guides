# AKS Bicep Example

```bash
RG=EphAKSLab
LOC=eastus2
CLUSTER_NAME=biceplab
VNET_NAME=biceplabvnet

az group create -n $RG -l $LOC

# Parameters from the Bicep file
export SYSPOOL_NODE_COUNT=3
export USER_POOL_NAME="user"
export USER_POOL_COUNT=3
export USER_POOL_VM_SIZE="standard_d2s_v3"
export SYSTEM_POOL_VM_SIZE="standard_d2s_v3"
export SERVICE_CIDR="10.100.0.0/16"
export DNS_SERVICE_IP="10.100.0.10"
export POD_CIDR="10.244.0.0/16"
export SSH_KEY=$(cat ~/.ssh/id_rsa.pub) # Replace with your actual SSH public key
export LINUX_ADMIN_USER="azureuser"

# Create a vnet and subnet
az network vnet create \
-g $RG \
-n $VNET_NAME \
--address-prefix 10.200.0.0/16 \
--subnet-name aks-systempool-subnet \
--subnet-prefix 10.200.0.0/24 

az network vnet subnet create \
-g $RG \
--vnet-name $VNET_NAME \
-n aks-userpool-subnet \
--address-prefix 10.200.1.0/24

export SYSTEM_POOL_VNET_SUBNET_ID=$(az network vnet subnet show -g $RG --vnet-name $VNET_NAME -n aks-systempool-subnet -o tsv --query id)
export USER_POOL_VNET_SUBNET_ID=$(az network vnet subnet show -g $RG --vnet-name $VNET_NAME -n aks-userpool-subnet -o tsv --query id)

az monitor log-analytics workspace create \
--resource-group $RG \
--workspace-name la-biceplab \
--location $LOC

export LA_WORKSPACE_ID=$(az monitor log-analytics workspace show -g $RG -n la-biceplab -o tsv --query id)

az deployment group create \
--resource-group $RG \
--template-file ./bicep/aks.bicep \
--parameters \
clusterName=$CLUSTER_NAME \
location=$LOC \
syspoolNodeCount=$SYSPOOL_NODE_COUNT \
userPoolName=$USER_POOL_NAME \
systemPoolVnetSubnetID=$SYSTEM_POOL_VNET_SUBNET_ID \
userPoolVnetSubnetID=$USER_POOL_VNET_SUBNET_ID \
userPoolCount=$USER_POOL_COUNT \
userPoolVMSize=$USER_POOL_VM_SIZE \
systemPoolVMSize=$SYSTEM_POOL_VM_SIZE \
serviceCidr=$SERVICE_CIDR \
dnsServivceIP=$DNS_SERVICE_IP \
podCidr=$POD_CIDR \
sshKey="$SSH_KEY" \
linuxAdminUser=$LINUX_ADMIN_USER \
logAnalyticsWorkspaceId=$LA_WORKSPACE_ID
```