#!/bin/bash
RG=EphAKSKubenetUDR
ACRNAME=kubenetdemoacr
CLUSTERNAME=kubenetudr
LOCATION=eastus
KEYVAULTNAME=griffkv3
FIREWALLNAME=aks-firewall

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
    
az network vnet subnet update \
    --resource-group $RG \
    --vnet-name aksvnet \
    --name acrSubnet \
    --disable-private-endpoint-network-policies

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
# az network firewall application-rule create \
# -g $RG \
# -f $FIREWALLNAME \
# --collection-name 'aksfwar' \
# -n 'fqdn' \
# --source-addresses '*' \
# --protocols 'http=80' 'https=443' \
# --target-fqdns "auth.docker.io,registry-1.docker.io,index.docker.io" \
# --action allow --priority 100


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



# Create an Azure Container Registry
az acr create \
-g $RG \
-n $ACRNAME \
--sku Premium \
--public-network-enabled false

# Create Private Link for ACR
az network private-dns zone create \
  --resource-group $RG \
  --name "kubenetdemo.azurecr.io"

# Associate private dns with vnet
az network private-dns link vnet create \
  --resource-group $RG \
  --zone-name "kubenetdemo.azurecr.io" \
  --name MyDNSLink \
  --virtual-network aksvnet \
  --registration-enabled false

# Get Registry ID
REGISTRY_ID=$(az acr show --name $ACRNAME --query 'id' --output tsv)

az network private-endpoint create \
    --name myPrivateEndpoint \
    --resource-group $RG \
    --vnet-name aksvnet \
    --subnet acrSubnet \
    --private-connection-resource-id $REGISTRY_ID \
    --group-ids registry \
    --connection-name myConnection

NETWORK_INTERFACE_ID=$(az network private-endpoint show \
  --name myPrivateEndpoint \
  --resource-group $RG \
  --query 'networkInterfaces[0].id' \
  --output tsv)

az network private-dns record-set a create \
  --name $ACRNAME \
  --zone-name kubenetdemo.azurecr.io \
  --resource-group $RG

# Specify registry region in data endpoint name
az network private-dns record-set a create \
  --name ${ACRNAME}.${LOCATION}.data \
  --zone-name kubenetdemo.azurecr.io \
  --resource-group $RG

  PRIVATE_IP=$(az resource show \
  --ids $NETWORK_INTERFACE_ID \
  --api-version 2019-04-01 \
  --query 'properties.ipConfigurations[1].properties.privateIPAddress' \
  --output tsv)

  DATA_ENDPOINT_PRIVATE_IP=$(az resource show \
  --ids $NETWORK_INTERFACE_ID \
  --api-version 2019-04-01 \
  --query 'properties.ipConfigurations[0].properties.privateIPAddress' \
  --output tsv)


  az network private-dns record-set a add-record \
  --record-set-name $ACRNAME \
  --zone-name kubenetdemo.azurecr.io \
  --resource-group $RG \
  --ipv4-address $PRIVATE_IP

# Specify registry region in data endpoint name
az network private-dns record-set a add-record \
  --record-set-name ${ACRNAME}.${LOCATION}.data \
  --zone-name kubenetdemo.azurecr.io \
  --resource-group $RG \
  --ipv4-address $DATA_ENDPOINT_PRIVATE_IP

# Create the AKS Cluster
az aks create \
-g $RG \
-n $CLUSTERNAME \
--vnet-subnet-id $SUBNET_ID \
--network-plugin kubenet \
--node-osdisk-diskencryptionset-id $diskEncryptionSetId \
--enable-aad \
--enable-addons monitoring \
--attach-acr $ACRNAME \
--outbound-type userDefinedRouting 

# Get Cluster Credentials
az aks get-credentials -g $RG -n $CLUSTERNAME