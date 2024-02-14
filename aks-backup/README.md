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
RG=EphAKSBackupLab6
LOC=eastus
CLUSTER_NAME=aksbackuplab6
VNET_NAME=aksbackuplab5
ADMIN_GROUP_ID=c88a3ffc-8e42-4108-9026-ba1073b66126
STORAGE_ACCT_NAME=griffaksbackup6
SUBSCRIPTION_ID=$(az account show -o tsv --query id)
BACKUP_VAULT_NAME=aksdemobackupvault6

# Create Resource Group 
az group create -n $RG -l $LOC

RG_ID=$(az group show -n $RG -o tsv --query id)

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

AKS_CLUSTER_ID=$(az aks show -g $RG -n $CLUSTER_NAME -o tsv --query id)
AKS_CLUSTER_MI=$(az aks show -g $RG -n $CLUSTER_NAME -o tsv --query identity.principalId)
AKS_CLUSTER_MC_RG=$(az aks show -g $RG -n $CLUSTER_NAME -o tsv --query nodeResourceGroup)
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
--scope $STORAGE_ACCT_ID

az dataprotection backup-vault create \
--resource-group $RG \
--vault-name $BACKUP_VAULT_NAME \
--location $LOC \
--type SystemAssigned \
--storage-settings datastore-type="VaultStore" type="LocallyRedundant"

BACKUP_VAULT_ID=$(az dataprotection backup-vault show -g $RG --vault-name $BACKUP_VAULT_NAME -o tsv --query id)

az aks trustedaccess rolebinding create \
-g $RG \
--cluster-name $CLUSTER_NAME \
-n aksdemobinding \
--source-resource-id $(az dataprotection backup-vault show -g $RG -v $BACKUP_VAULT_NAME --query id -o tsv) --roles Microsoft.DataProtection/backupVaults/backup-operator

# Get the backup vault system assigned managed identity ID
BACKUP_VAULT_MI=$(az dataprotection backup-vault show -g $RG -v $BACKUP_VAULT_NAME -o tsv --query identity.principalId)

az role assignment create \
--assignee-object-id $BACKUP_VAULT_MI \
--role 'Reader' \
--scope $AKS_CLUSTER_ID

az role assignment create \
--assignee-object-id $BACKUP_VAULT_MI \
--role 'Reader' \
--scope $RG_ID

az role assignment create \
--assignee-object-id $BACKUP_VAULT_MI \
--role 'Storage Blob Data Reader' \
--scope $STORAGE_ACCT_ID

az role assignment create \
--assignee-object-id $BACKUP_VAULT_MI \
--role 'Storage Account Contributor' \
--scope $STORAGE_ACCT_ID

az role assignment create \
--assignee-object-id $BACKUP_VAULT_MI \
--role 'Contributor' \
--scope $STORAGE_ACCT_ID


az role assignment create \
--assignee-object-id $BACKUP_VAULT_MI \
--role 'Storage Account Contributor' \
--scope $STORAGE_ACCT_ID

az role assignment create \
--assignee-object-id $BACKUP_VAULT_MI \
--role 'Data Operator for Managed Disks' \
--scope $RG_ID

az role assignment create \
--assignee-object-id $BACKUP_VAULT_MI \
--role 'Disk Snapshot Contributor' \
--scope $RG_ID

az role assignment create \
--assignee-object-id $BACKUP_VAULT_MI \
--role 'Disk Backup Reader' \
--scope $RG_ID

az role assignment create \
--assignee-object-id $AKS_CLUSTER_MI \
--role 'Contributor' \
--scope $RG_ID

az role assignment create \
--assignee-object-id $AKSBACKUP_IDENTITY \
--role 'Storage Account Contributor' \
--scope $STORAGE_ACCT_ID

```

### Create and apply a backup policy

```bash
az dataprotection backup-policy get-default-policy-template --datasource-type AzureKubernetesService -o json > akspolicy.json

az dataprotection backup-policy create -g $RG --vault-name $BACKUP_VAULT_NAME -n demopolicy --policy akspolicy.json

BACKUP_POLICY_ID=$(az dataprotection backup-policy show -g $RG --vault-name $BACKUP_VAULT_NAME -n demopolicy -o tsv --query id)

az dataprotection backup-instance initialize-backupconfig --datasource-type AzureKubernetesService -o json > aksbackupconfig.json

az dataprotection backup-instance initialize \
--datasource-id $AKS_CLUSTER_ID \
--datasource-location $LOC \
--datasource-type AzureKubernetesService \
--policy-id $BACKUP_POLICY_ID \
--backup-configuration ./aksbackupconfig.json \
--friendly-name ecommercebackup \
--snapshot-resource-group-name $RG -o json > backupinstance.json


az dataprotection backup-instance validate-for-backup \
--backup-instance ./backupinstance.json \
--ids $BACKUP_VAULT_ID

az dataprotection backup-instance update-msi-permissions -y \
--datasource-type AzureKubernetesService \
--operation Backup \
--permissions-scope ResourceGroup \
--vault-name $BACKUP_VAULT_NAME \
--resource-group $RG \
--backup-instance backupinstance.json

az dataprotection backup-instance create \
--backup-instance  backupinstance.json --resource-group $RG --vault-name $BACKUP_VAULT_NAME

BACKUP_INSTANCE_ID=$(az dataprotection backup-instance list-from-resourcegraph --datasource-type AzureKubernetesService --datasource-id $AKS_CLUSTER_ID --query '[0].id' -o tsv)

az dataprotection backup-instance list-from-resourcegraph \
--datasource-type AzureKubernetesService \
--datasource-id $AKS_CLUSTER_ID -o yaml --query aksAssignedIdentity.id

az dataprotection backup-instance adhoc-backup --rule-name "Default" --ids $BACKUP_INSTANCE_ID 

```