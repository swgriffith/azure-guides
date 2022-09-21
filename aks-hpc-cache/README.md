# Setting up AKS with Azure HPC Cache

## Create the Resource Group and Vnet

```bash
# Set variables
RG=EphAKSHPCCache
LOC=eastus
VNET_NAME=labvnet
AKS_CLUSTER_NAME=democluster

# Create the resource group
az group create -g $RG -l $LOC

# Create Vnet
az network vnet create \
-g $RG \
-n $VNET_NAME \
--address-prefix 10.40.0.0/16 \
--subnet-name aks-subnet --subnet-prefix 10.40.0.0/24

az network vnet subnet create \
-g $RG \
--vnet-name $VNET_NAME \
-n hpc-cache-subnet \
--address-prefixes 10.40.1.0/24

# Get the subnet resource IDs
AKS_SUBNET_ID=$(az network vnet subnet show -g $RG --vnet-name $VNET_NAME -n aks-subnet --query id -o tsv)
```

## Create the AKS Cluster

```bash
# Create the AKS Cluster
az aks create \
-g $RG \
-n $AKS_CLUSTER_NAME \
--vnet-subnet-id $AKS_SUBNET_ID \
--network-plugin kubenet

# Get the cluster credentials
az aks get-credentials -g $RG -n $AKS_CLUSTER_NAME
```

## Create the HPC Cache

```bash
# Set Variables
CACHE_NAME=aksdemocache
CACHE_SIZE="3072"
CACHE_SKU="Standard_2G"

# Get the HPC Cache Subnet IP
HPC_CACHE_SUBNET_ID=$(az network vnet subnet show -g $RG --vnet-name $VNET_NAME -n hpc-cache-subnet --query id -o tsv)

az hpc-cache create \
--resource-group $RG \
--name $CACHE_NAME \
--location $LOC \
--cache-size-gb $CACHE_SIZE \
--subnet $HPC_CACHE_SUBNET_ID \
--sku-name $CACHE_SKU

```

### Create a blob account for the storage target

```bash
# Set Variables
# Must be unique
BLOB_ACCT_NAME=hpccachetest9494

az storage account create \
--name $BLOB_ACCT_NAME \
--resource-group $RG \
--location $LOC \
--sku Standard_LRS \
--encryption-services blob

# Create the storage container
az storage container create \
--account-name $BLOB_ACCT_NAME \
--name testdata 

BLOB_ACCT_ID=$(az storage account show -g $RG -n $BLOB_ACCT_NAME -o tsv --query id)
```

Find the 'HPC Cache Resource Provider' service principal and grant it 'Storage Account Contributor' and 'Storage Blob Data Contributor' access.

> **Warning:**
> Depending on when you registered the HPC Cache service provider, your name may vary. If you cant find 'HPC Cache Resource Provider', then try looking for 'StorageCache'as I have below.

```bash
# Get the App ID for the resource provider user
HPC_RP_USER_ID=$(az ad sp list --display-name "StorageCache" -o tsv --query '[0].id')

az role assignment create --assignee $HPC_RP_USER_ID \
--role "Storage Account Contributor" \
--scope $BLOB_ACCT_ID

az role assignment create --assignee $HPC_RP_USER_ID \
--role "Storage Blob Data Contributor" \
--scope $BLOB_ACCT_ID
```

### Create a storage target for HPC Cache

```bash
az hpc-cache blob-storage-target add \
--resource-group $RG \
--cache-name $CACHE_NAME \
--name "blob-target1" \
--storage-account $BLOB_ACCT_ID \
--container-name "testdata" \
--virtual-namespace-path "/testdata"
```