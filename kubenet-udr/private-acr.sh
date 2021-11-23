#!/bin/bash
RG=EphAKSKubenetUDR3
ACRNAME=kubenetdemoacr3
CLUSTERNAME=kubenetudr3
LOCATION=eastus
KEYVAULTNAME=griffkv4
FIREWALLNAME=aks-firewall
LA_WORKSPACE_NAME=grifflademo

###### Setup ACR ######

# Add ACR Subnet
az network vnet subnet update \
    --resource-group $RG \
    --vnet-name aksvnet \
    --name acrSubnet \
    --disable-private-endpoint-network-policies



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
