# Calling AKS From Python

## Introduction

The following walkthrough shows the steps needed to make a call to the kubernetes API server from python against an AKS cluster using Azure Active Directory Integrated Authentication, AKS Azure AD Role Based Access Control and with local accounts disabled. It assumes the following has already been configured:

## AKS Setup

### Identity Setup

For this example we'll use the AzureCLICredential object to leverage the logged in user credential, but you can update as needed. First we'll need to sign into via the Azure CLI.

```bash
# Set an env var for your subscription ID
export AZURE_SUBSCRIPTION_ID='INSERT SUBSCRIPTION ID'

# Login via the CLI
az login

# Set the subscription
az account set -s $AZURE_SUBSCRIPTION_ID
```

```bash
# Set variables for the group and user names
export AAD_GROUP_NAME='griffith-cluster-admins'
export USER_NAME='cluster-admin'

# Create the Azure AD Cluster Admin Group
az ad group create --display-name $AAD_GROUP_NAME --mail-nickname $AAD_GROUP_NAME

# Get the Group Object ID for later
AAD_GROUP_ID=$(az ad group show -g $AAD_GROUP_NAME -o tsv --query id)

# Create the Service Principal
# NOTE: THIS IS VERY BROAD ACCESS...for demo only. You will want more fine grained access
az ad sp create-for-rbac --name $USER_NAME --role 'Contributor' --scopes /subscriptions/$AZURE_SUBSCRIPTION_ID

########################################################
# Make note of the AppId and Password outputs for later
########################################################
export TENANT_ID=''
export APP_ID=''
export PASSWD=''
export APP_OBJ_ID=$(az ad sp show --id $APP_ID -o tsv --query id)

az ad group member add --group $AAD_GROUP_NAME --member-id $APP_OBJ_ID

# At this point we'll also get the App ID that represents AKS
export AKS_AAD_SERVER_ID=$(az ad sp list --display-name "Azure Kubernetes Service AAD Server" -o tsv --query '[0].appId')
```

### Create the AKS Cluster

```bash
# Set the Resource Group Name
export RG=AKSDemo
export LOC=eastus
export CLUSTER_NAME=democluster

# Create the Resource Group
az group create -n $RG -l $LOC

# Create the cluster with all the AAD config needed
az aks create \
-g $RG \
-n $CLUSTER_NAME \
--enable-aad \
--enable-azure-rbac \
--aad-admin-group-object-ids $AAD_GROUP_ID \
--disable-local-accounts
```

## Python Setup

For this we'll use the Azure SDK for Python for several calls.

[Azure SKD For Python](https://learn.microsoft.com/en-us/azure/developer/python/sdk/azure-sdk-overview)

```bash
# Install the azure-identity package
pip install azure-identity

# Install the Container Service package
pip install azure.mgmt.containerservice

# Install ADAL
pip install adal

# Install Kubernetes
pip install kubernetes
```



