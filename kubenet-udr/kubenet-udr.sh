#!/bin/bash
RG=EphAKSKubenetUDR3
ACRNAME=kubenetdemoacr3
CLUSTERNAME=kubenetudr3
LOCATION=eastus
KEYVAULTNAME=griffkv4
FIREWALLNAME=aks-firewall
LA_WORKSPACE_NAME=grifflademo

# Create Resource Group
az group create -n $RG -l eastus

# Create Vnet
az network vnet create \
-g $RG \
-n aksvnet \
--address-prefix 10.40.0.0/16 \
--subnet-name aks --subnet-prefix 10.40.0.0/24


# Create Azure Firewall Subnet
az network vnet subnet create \
    --resource-group $RG \
    --vnet-name aksvnet \
    --name AzureFirewallSubnet \
    --address-prefix 10.40.1.0/24

# Create Azure Container Registry Subnet
az network vnet subnet create \
    --resource-group $RG \
    --vnet-name aksvnet \
    --name acrSubnet \
    --address-prefix 10.40.2.0/24
    
# Create Azure Firewall Public IP
az network public-ip create -g $RG -n azfirewall-ip -l $LOCATION --sku "Standard"

# Create Azure Firewall
az extension add --name azure-firewall
az network firewall create -g $RG -n $FIREWALLNAME -l $LOCATION --enable-dns-proxy true

# Configure Firewall IP Config
az network firewall ip-config create -g $RG -f $FIREWALLNAME -n aks-firewallconfig --public-ip-address azfirewall-ip --vnet-name aksvnet

# Capture Firewall IP Address for Later Use
FWPUBLIC_IP=$(az network public-ip show -g $RG -n azfirewall-ip --query "ipAddress" -o tsv)
FWPRIVATE_IP=$(az network firewall show -g $RG -n $FIREWALLNAME --query "ipConfigurations[0].privateIpAddress" -o tsv)

# Create Route Table
az network route-table create \
-g $RG \
-n aksdefaultroutes

# Create Route
az network route-table route create \
-g $RG \
--route-table-name aksdefaultroutes \
-n firewall-route \
--address-prefix 0.0.0.0/0 \
--next-hop-type VirtualAppliance \
--next-hop-ip-address $FWPRIVATE_IP

az network route-table route create \
-g $RG \
--route-table-name aksdefaultroutes \
-n internet-route \
--address-prefix $FWPUBLIC_IP/32 \
--next-hop-type Internet

# Add FW Network Rules

az network firewall network-rule create \
-g $RG \
-f $FIREWALLNAME \
--collection-name 'aksfwnr' \
-n 'apiudp' \
--protocols 'UDP' \
--source-addresses '*' \
--destination-addresses "AzureCloud.$LOCATION" \
--destination-ports 1194 --action allow --priority 100

az network firewall network-rule create \
-g $RG \
-f $FIREWALLNAME \
--collection-name 'aksfwnr' \
-n 'apitcp' \
--protocols 'TCP' \
--source-addresses '*' \
--destination-addresses "AzureCloud.$LOCATION" \
--destination-ports 9000

az network firewall network-rule create \
-g $RG \
-f $FIREWALLNAME \
--collection-name 'aksfwnr' \
-n 'time' \
--protocols 'UDP' \
--source-addresses '*' \
--destination-fqdns 'ntp.ubuntu.com' \
--destination-ports 123

# Add FW Application Rules
az network firewall application-rule create \
-g $RG \
-f $FIREWALLNAME \
--collection-name 'aksfwar' \
-n 'fqdn' \
--source-addresses '*' \
--protocols 'http=80' 'https=443' \
--fqdn-tags "AzureKubernetesService" \
--action allow --priority 100

# Docker Hub Rules
az network firewall application-rule create \
-g $RG \
-f $FIREWALLNAME \
--collection-name 'aksfwdocker' \
-n 'docker' \
--source-addresses '*' \
--protocols 'http=80' 'https=443' \
--target-fqdns auth.docker.io registry-1.docker.io index.docker.io dseasb33srnrn.cloudfront.net production.cloudflare.docker.com \
--action allow --priority 101

# Associate Route Table to AKS Subnet
az network vnet subnet update \
-g $RG \
--vnet-name aksvnet \
-n aks \
--route-table aksdefaultroutes

# Get the subnet id
SUBNET_ID=$(az network vnet show -g $RG -n aksvnet -o tsv --query "subnets[?name=='aks'].id")

######## Setup Disk Encryption ########
# Create Key Vault
az keyvault create -n $KEYVAULTNAME -g $RG -l $LOCATION  --enable-purge-protection true --enable-soft-delete true

# Create the disk encryption key
az keyvault key create --vault-name $KEYVAULTNAME --name aksdiskkey

# Retrieve the Key Vault Id and store it in a variable
keyVaultId=$(az keyvault show --name $KEYVAULTNAME -o tsv --query id)

# Retrieve the Key Vault key URL and store it in a variable
keyVaultKeyUrl=$(az keyvault key show --vault-name $KEYVAULTNAME  --name aksdiskkey  --query key.kid -o tsv)

# Create a DiskEncryptionSet
az disk-encryption-set create -n aksDiskEncryptionSetName  -l $LOCATION  -g $RG --source-vault $keyVaultId --key-url $keyVaultKeyUrl

# Retrieve the DiskEncryptionSet value and set a variable
desIdentity=$(az disk-encryption-set show -n aksDiskEncryptionSetName  -g $RG --query identity.principalId -o tsv)

# Update security policy settings
az keyvault set-policy -n $KEYVAULTNAME -g $RG --object-id $desIdentity --key-permissions wrapkey unwrapkey get

# Retrieve the DiskEncryptionSet value and set a variable
diskEncryptionSetId=$(az disk-encryption-set show -n aksDiskEncryptionSetName -g $RG --query id -o tsv)

# Create Log Analytics Workspace
az monitor log-analytics workspace create \
--resource-group $RG \
--workspace-name $LA_WORKSPACE_NAME

# Get Workspace ID
LA_WORKSPACE_ID=$(az monitor log-analytics workspace show -g $RG -n $LA_WORKSPACE_NAME -o tsv --query id)

# Create the AKS Cluster
az aks create \
-g $RG \
-n $CLUSTERNAME \
--vnet-subnet-id $SUBNET_ID \
--network-plugin kubenet \
--node-osdisk-diskencryptionset-id $diskEncryptionSetId \
--enable-aad \
--enable-addons monitoring \
--workspace-resource-id "$LA_WORKSPACE_ID" \
--outbound-type userDefinedRouting 

# Get Cluster Admin Credentials
az aks get-credentials -g $RG -n $CLUSTERNAME --admin

# Add admin role binding for user
cat << EOF | kubectl apply -f -
kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: griff-admin
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: User
  name: "stgriffi@microsoft.com"
EOF

# Get non-admin credential
az aks get-credentials -g $RG -n $CLUSTERNAME


