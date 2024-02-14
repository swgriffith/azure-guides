# AKS Backup Setup

```bash
# Register the provider
az provider register --namespace Microsoft.KubernetesConfiguration

# Check the registration status
az provider show -n Microsoft.KubernetesConfiguration -o table
```

### Enable Trusted Access


```bash
# Register Trusted Access Preview
az feature register --namespace "Microsoft.ContainerService" --name "TrustedAccessPreview"

# Check Registration Status
az feature show --namespace "Microsoft.ContainerService" --name "TrustedAccessPreview"
```

### Update the AKS Provider

```bash
az provider register --namespace Microsoft.ContainerService
```

### Create the VNet and Cluster

```bash
RG=EphAKSBackupLab
LOC=eastus
CLUSTER_NAME=aksbackuplab
VNET_NAME=aksbackuplab
ADMIN_GROUP_ID=c88a3ffc-8e42-4108-9026-ba1073b66126
STORAGE_ACCT_NAME=griffaksbackup
SUBSCRIPTION_ID=$(az account show -o tsv --query id)
BACKUP_VAULT_NAME=aksdemobackupvault

# Create Resource Group 
az group create -n $RG -l $LOC

# Create Vnet
az network vnet create \
-g $RG \
-n $VNET_NAME \
--address-prefix 10.140.0.0/16 \
--subnet-name aks \
--subnet-prefix 10.140.0.0/24

# Get the cluster VNet Subnet ID
VNET_SUBNET_ID=$(az network vnet subnet show -g $RG --vnet-name $VNET_NAME -n aks -o tsv --query id)

# Create AKS Cluster
az aks create \
-g $RG \
-n $CLUSTER_NAME \
--enable-private-cluster \
--enable-aad \
--enable-managed-identity \
--aad-admin-group-object-ids $ADMIN_GROUP_ID \
--disable-local-accounts \
--network-plugin azure \
--network-plugin-mode overlay \
--vnet-subnet-id $VNET_SUBNET_ID
```

### Create the storage account

```bash
# Create a blob storage account
az storage account create \
--name $STORAGE_ACCT_NAME \
--resource-group $RG \
--location $LOC \
--sku Standard_LRS \
--encryption-services blob

# Get the resource ID of the storage account
STORAGE_ACCT_ID=$(az storage account show -g $RG -n $STORAGE_ACCT_NAME --query id -o tsv)

# Create a storage account container with login auth mode enabled
az storage container create --account-name $STORAGE_ACCT_NAME --name data --auth-mode login
```

### Install the AKS Backup Extension

```bash
az k8s-extension create \
--name azure-aks-backup \
--extension-type microsoft.dataprotection.kubernetes \
--scope cluster \
--cluster-type managedClusters \
--cluster-name $CLUSTER_NAME \
--resource-group $RG \
--release-train stable \
--configuration-settings blobContainer=data storageAccount=${STORAGE_ACCT_NAME} storageAccountResourceGroup=${RG} storageAccountSubscriptionId=${SUBSCRIPTION_ID}

# Check status
az k8s-extension show \
--name azure-aks-backup \
--cluster-type managedClusters \
--cluster-name $CLUSTER_NAME \
--resource-group $RG

AKSBACKUP_IDENTITY=$(az k8s-extension show --name azure-aks-backup --cluster-name $CLUSTER_NAME --resource-group $RG --cluster-type managedClusters -o tsv --query aksAssignedIdentity.principalId)

az role assignment create \
--assignee-object-id $AKSBACKUP_IDENTITY \
--role 'Storage Account Contributor' \
--scope /subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RG}/providers/Microsoft.Storage/storageAccounts/${STORAGE_ACCT_NAME}

az dataprotection backup-vault create --type "None" --location $LOC --azure-monitor-alerts-for-job-failures "Enabled" --storage-setting "[{type:'LocallyRedundant',datastore-type:'VaultStore'}]" --resource-group $RG --vault-name $BACKUP_VAULT_NAME

az aks trustedaccess rolebinding create \
-g $RG \
--cluster-name $CLUSTER_NAME \
-n aksdemobinding \
--source-resource-id $(az dataprotection backup-vault show -g $RG -v $BACKUP_VAULT_NAME --query id -o tsv) --roles Microsoft.DataProtection/backupVaults/backup-operator
```