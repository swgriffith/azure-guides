# AKS Backup Setup

## Introduction

In this walk through we'll demonstrate the CLI commands and setup needed to create an AKS Cluster, configured with Entra ID integrated auth and local accounts disabled and then enabling AKS Backup along with all required roles and permissions.

## Setup

For AKS Backup to work it will need access to the AKS Cluster. There are many ways to accomplish this, however AKS recently released support for '[Trusted Access](https://learn.microsoft.com/en-us/azure/aks/trusted-access-feature)', which enables an Azure Service to access the AKS API, so we'll use Trusted Access in this setup.

Trusted Access is still in preview, so we'll need to register the provider and enable the feature.

```bash
# Register the provider
az provider register --namespace Microsoft.KubernetesConfiguration

# Check the registration status
az provider show -n Microsoft.KubernetesConfiguration -o table

# Register Trusted Access Preview
az feature register --namespace "Microsoft.ContainerService" --name "TrustedAccessPreview"

# Check Registration Status
az feature show --namespace "Microsoft.ContainerService" --name "TrustedAccessPreview"

# Finally, re-register the ContainerService provider
az provider register --namespace Microsoft.ContainerService
```

### Create the VNet and Cluster

In our setup we'll bring our own Vnet, so lets set some environemnt variables and then create the resource group and Vnet.

>**Note:** Since we're setting this cluster up with Entra ID auth enabled and local accounts disabled we'll be setting an admin group ID for the cluster admins. You can leave this out if you dont plan on using Entra ID auth

```bash
RG=AKSBackupLab1
LOC=eastus
CLUSTER_NAME=aksbackuplab1
VNET_NAME=aksbackuplab-vnet
ADMIN_GROUP_ID=c88a3ffc-8e42-4108-9026-ba1073b66126
STORAGE_ACCT_NAME=aksbackuplabsa1
SUBSCRIPTION_ID=$(az account show -o tsv --query id)
TENANT_ID=$(az account show -o tsv --query tenantId)
BACKUP_VAULT_NAME=aksbackuplab-vault1

# Create Resource Group 
az group create -n $RG -l $LOC

# Get the resource group resource ID for later
RG_ID=$(az group show -n $RG -o tsv --query id)

# Create Vnet and subnet
az network vnet create \
-g $RG \
-n $VNET_NAME \
--address-prefix 10.140.0.0/16 \
--subnet-name aks \
--subnet-prefix 10.140.0.0/24

# Get the cluster VNet Subnet ID
VNET_SUBNET_ID=$(az network vnet subnet show -g $RG --vnet-name $VNET_NAME -n aks -o tsv --query id)
```

### Create the AKS Cluster

Next we'll create the AKS Cluster with the following configuration details, which are fairly common:

* Private Cluster API Server
* Entra ID Integrated Auth
* Cluster System Assigned Managed Identity
* User Provided Kubernetes Cluster Admin Entra Group ID
* Azure CNI Network Plugin - Overlay Mode
* User Provided Vnet/Subnet ID


```bash
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

Get various Cluster details for later use.

```bash
#Cluster Resource ID
AKS_CLUSTER_ID=$(az aks show -g $RG -n $CLUSTER_NAME -o tsv --query id)

# Cluster Managed Identity
AKS_CLUSTER_MI=$(az aks show -g $RG -n $CLUSTER_NAME -o tsv --query identity.principalId)

# Managed Cluster (MC_) resource group name
AKS_CLUSTER_MC_RG=$(az aks show -g $RG -n $CLUSTER_NAME -o tsv --query nodeResourceGroup)
```

### Create the storage account

Azure Backup uses an Azure Storage account, so lets create that account.

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

### Setup Private Link for the Blob Storage Account

```bash
az network private-dns zone create --name "privatelink.blob.core.windows.net" -g $RG

# Create an association link: 
# virtual-network is the consumer VNet, so it will be the ARO VNet $vnet_name
az network private-dns link vnet create \
--resource-group $RG \
--zone-name "privatelink.blob.core.windows.net" \
--name "privatelink.blob.core.windows.net" \
--virtual-network $VNET_NAME \
--registration-enabled false


# The private-endpoint must be created in the Consumer VNet/Subnet
az network private-endpoint create \
--name "aksbackup-private" \
--resource-group $RG \
--subnet $VNET_SUBNET_ID \
--private-connection-resource-id $STORAGE_ACCT_ID \
--group-id blob \
--location $LOC \
--connection-name "privateconn"

# Disable public network access to the storage account
az storage account update --name $STORAGE_ACCT_NAME --resource-group $RG --public-network-access Disabled

# Get the storage private endpoint resource ID
STORAGE_PRIVATE_ENDPOINT_ID=$(az network private-endpoint show --name "aksbackup-private" -g $RG --query id -o tsv)

# Get the network inteface ID for the storage private endpoint
NETWORK_INTERFACE_ID=$(az network private-endpoint show --name "aksbackup-private" -g $RG --query 'networkInterfaces[0].id' -o tsv)

# Get the storage private interface IP adddress
STORAGE_PRIVATE_LINK_IP=$(az resource show --ids $NETWORK_INTERFACE_ID \
  --api-version 2019-04-01 --query 'properties.ipConfigurations[0].properties.privateIPAddress' --output tsv)

# Create the A Record for the storage private IP
az network private-dns record-set a add-record -g $RG \
--record-set-name $STORAGE_ACCT_NAME \
--zone-name privatelink.blob.core.windows.net \
--ipv4-address $STORAGE_PRIVATE_LINK_IP
```

### Install the AKS Backup Extension

Now that the cluster and storage account are ready, we can install the AKS Backup extension in the cluster and configure AKS Backup. 

First, the extension install.

```bash

# Install the AKS Backup Extension
az k8s-extension create \
--name azure-aks-backup \
--extension-type microsoft.dataprotection.kubernetes \
--scope cluster \
--cluster-type managedClusters \
--cluster-name $CLUSTER_NAME \
--resource-group $RG \
--release-train stable \
--configuration-settings blobContainer=data storageAccount=${STORAGE_ACCT_NAME} storageAccountResourceGroup=${RG} storageAccountSubscriptionId=${SUBSCRIPTION_ID}

# Get the identity for the backup extension
AKSBACKUP_IDENTITY=$(az k8s-extension show --name azure-aks-backup --cluster-name $CLUSTER_NAME --resource-group $RG --cluster-type managedClusters -o tsv --query aksAssignedIdentity.principalId)

# Create the Azure Backup Data Protection Vault
az dataprotection backup-vault create \
--resource-group $RG \
--vault-name $BACKUP_VAULT_NAME \
--location $LOC \
--type SystemAssigned \
--storage-settings datastore-type="VaultStore" type="LocallyRedundant"

# Get the resource ID of the data protection Vault
BACKUP_VAULT_ID=$(az dataprotection backup-vault show -g $RG --vault-name $BACKUP_VAULT_NAME -o tsv --query id)

# Grant the backup vault trusted access to the AKS Cluster
az aks trustedaccess rolebinding create \
-g $RG \
--cluster-name $CLUSTER_NAME \
-n aksdemobinding \
--source-resource-id $(az dataprotection backup-vault show -g $RG -v $BACKUP_VAULT_NAME --query id -o tsv) --roles Microsoft.DataProtection/backupVaults/backup-operator
```

### Grant Required Permissions

Before trying to create our first backup, now that we have all other resource created, we need to add all the required permissions as documented [here](https://learn.microsoft.com/en-us/azure/backup/azure-kubernetes-service-cluster-backup-concept#required-roles-and-permissions)

```bash
# Get the backup vault system assigned managed identity ID
BACKUP_VAULT_MI=$(az dataprotection backup-vault show -g $RG -v $BACKUP_VAULT_NAME -o tsv --query identity.principalId)

# Grant Backup Vault Identity Reader on the AKS Cluster Resource
az role assignment create \
--assignee-object-id $BACKUP_VAULT_MI \
--role 'Reader' \
--scope $AKS_CLUSTER_ID

# Grant the Backup Vault Identity Reader on the Snapshot resource group
az role assignment create \
--assignee-object-id $BACKUP_VAULT_MI \
--role 'Reader' \
--scope $RG_ID

# Grant the AKS Cluster identity Contributor on the Snapshot resource group
az role assignment create \
--assignee-object-id $AKS_CLUSTER_MI \
--role 'Contributor' \
--scope $RG_ID

# Grant the AKS Backup Exention identity Storage Account Contributor on the Storage Account
az role assignment create \
--assignee-object-id $AKSBACKUP_IDENTITY \
--role 'Storage Account Contributor' \
--scope $STORAGE_ACCT_ID

# Grant the Backup Vault Identity Data Operator for Managed Disks
# on the snapshot resource group
az role assignment create \
--assignee-object-id $BACKUP_VAULT_MI \
--role 'Data Operator for Managed Disks' \
--scope $RG_ID

# Grant the Backup Vault Identity Disk Snapshot Contributor
# on the snapshot resource group
az role assignment create \
--assignee-object-id $BACKUP_VAULT_MI \
--role 'Disk Snapshot Contributor' \
--scope $RG_ID

# Grant the Backup Vault Identity Storage Blob Reader
# on the snapshot resource group
az role assignment create \
--assignee-object-id $BACKUP_VAULT_MI \
--role 'Storage Blob Data Reader' \
--scope $STORAGE_ACCT_ID

az role assignment create \
--assignee-object-id $BACKUP_VAULT_MI \
--role 'Storage Account Contributor' \
--scope $STORAGE_ACCT_ID

az role assignment create \
--assignee-object-id $AKSBACKUP_IDENTITY \
--role 'Contributor' \
--scope $RG_ID

az role assignment create \
--assignee-object-id $AKSBACKUP_IDENTITY \
--role 'Storage Blob Data Owner' \
--scope $STORAGE_ACCT_ID
```

### Create and apply a backup policy

Now we're ready to create and apply a backup policy. Azure CLI has tools to help generate a default policy. 

```bash
# Generate a default policy template
az dataprotection backup-policy get-default-policy-template --datasource-type AzureKubernetesService -o json > akspolicy.json

# Create the backup policy from the default template
az dataprotection backup-policy create -g $RG --vault-name $BACKUP_VAULT_NAME -n demopolicy --policy akspolicy.json

# Get the backup policy ID for later
BACKUP_POLICY_ID=$(az dataprotection backup-policy show -g $RG --vault-name $BACKUP_VAULT_NAME -n demopolicy -o tsv --query id)

# Get the backup instance config
az dataprotection backup-instance initialize-backupconfig --datasource-type AzureKubernetesService -o json > aksbackupconfig.json

# Initialize the backup instance using the config and policy and then output the instance data
az dataprotection backup-instance initialize \
--datasource-id $AKS_CLUSTER_ID \
--datasource-location $LOC \
--datasource-type AzureKubernetesService \
--policy-id $BACKUP_POLICY_ID \
--backup-configuration ./aksbackupconfig.json \
--friendly-name ecommercebackup \
--snapshot-resource-group-name $RG -o json > backupinstance.json

# Validate the backup instance is properly configured
az dataprotection backup-instance validate-for-backup \
--backup-instance ./backupinstance.json \
--ids $BACKUP_VAULT_ID

# az dataprotection backup-instance update-msi-permissions -y \
# --datasource-type AzureKubernetesService \
# --operation Backup \
# --permissions-scope ResourceGroup \
# --vault-name $BACKUP_VAULT_NAME \
# --resource-group $RG \
# --backup-instance backupinstance.json

az dataprotection backup-instance create \
--backup-instance  backupinstance.json --resource-group $RG --vault-name $BACKUP_VAULT_NAME

# Get the backup instance ID
BACKUP_INSTANCE_ID=$(az dataprotection backup-instance list-from-resourcegraph --datasource-type AzureKubernetesService --datasource-id $AKS_CLUSTER_ID --query '[0].id' -o tsv)

# Trigger the adhoc backup
az dataprotection backup-instance adhoc-backup --rule-name "BackupHourly" --ids $BACKUP_INSTANCE_ID  --retention-tag-override "Default"
```