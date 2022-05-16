#!/bin/bash
RG=EphCNILockDown
CLUSTERNAME=onlockdown
LOCATION=eastus
FIREWALLNAME=aks-firewall

# Create Resource Group
az group create -n $RG -l $LOCATION

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

# Create Pod Subnet
az network vnet subnet create \
    --resource-group $RG \
    --vnet-name aksvnet \
    --name pods \
    --delegations 'Microsoft.ContainerService/managedClusters' \
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

# Create the AKS Cluster
az aks create \
-g $RG \
-n $CLUSTERNAME \
--vnet-subnet-id $SUBNET_ID \
--network-plugin azure \
--outbound-type userDefinedRouting 

# Get Cluster Admin Credentials
az aks get-credentials -g $RG -n $CLUSTERNAME

