# AKS gMSA Setup

## Pre-requisite

* Customer will require knowledge on how to create AKS cluster, Azure policy, Azure AD Domain Controller, and Kubernetes gMSA verifications.
* An Active Directory Domain Controller
  * Needs to be on an Azure VNET, but can be physically on-prem if Express Route or VPN is set up
  * Someone with domain admin creds will need to set up the gMSA account
* Support versions:
  * gMSAv1
  * AKS 1.16.10 and above.
* This procedure will require both to run on linux and windows.
  * For Linux recommend using cloud shell bash or WSL as some scripts are writing in bash.
  * You will need az cli, kubectl (az cli or PS)  should be installed

## Create the Cluster

```bash
# Set up Env Variables
resourceGroup=<RG NAME>
clusterName=<CLUSTER NAME>
USERNAME_WIN="azureuser"
PASSWORD_WIN="<PASSWD>"

# Create the cluster
az aks create \
--resource-group $resourceGroup \
--name $clusterName \
--windows-admin-password $PASSWORD_WIN \
--windows-admin-username $USERNAME_WIN \
--load-balancer-sku standard \
--network-policy azure \
--network-plugin azure \
-c 1 \
--vnet-subnet-id "<INSERT SUBNET RESOURCE ID>"

# Add Windows Node Pool
az aks nodepool add --resource-group $resourceGroup --cluster-name $clusterName --os-type Windows --name npwin1 --node-count 2
```
## Get Settings for Domain Join

```bash
# Set the domain name and domain admin user name
domainName="stevegriffith.io"
domainAdminUserName="griffith"
domainAdminPasswd="q1b66HSnurY9#"


# Get the Windows Nodepool VMSS RG Name
VmssResourceGroupName=$(az aks show -g $resourceGroup -n $clusterName -o tsv --query nodeResourceGroup)

# Get the Windows Nodepool VMSS Name
VmssName=$(az vmss list -g $VmssResourceGroupName -o tsv --query "[?virtualMachineProfile.storageProfile.imageReference.offer=='aks-windows'].name")

# Build the domain settings json
# cat <<EOF >> domainSettings.json
# {"Name" = "$domainName";
# "User" = "$domainName\\$domainAdminUserName";
# "Restart" = "true";
# "Options" = 3;
# }
# EOF

az vmss extension set \
--vmss-name $VmssName \
--extension-instance-name vmssjoindomain \
--resource-group $VmssResourceGroupName \
--version 1.3 \
--publisher "Microsoft.Compute" \
--name JsonADDomainExtension \
--settings "{\"Name\":\"$domainName\",\"User\":\"$domainName\\$domainAdminUserName\",\"Restart\":\"true\",\"Options\":3}" \
--protected-settings "{\"Password\":\"$domainAdminPasswd\"}"

az vmss update-instances --instance-ids '*' \
--resource-group $VmssResourceGroupName \
--name $VmssName


```