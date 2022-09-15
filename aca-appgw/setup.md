# Setting up ACA Private with Azure App Gateway

## Setup

### Enable ACA

```bash
# Install/Upgrade the ACA Extension
az extension add --name containerapp --upgrade

# Register the providers
az provider register --namespace Microsoft.App
az provider register --namespace Microsoft.OperationalInsights
```

### Create the network

```bash
# Set Variables
RESOURCE_GROUP=EphACALab2
LOCATION=eastus2

# Create Resource Group
az group create -n $RESOURCE_GROUP -l $LOCATION

VNET_NAME=acavnet

# Create Vnet
az network vnet create \
-g $RESOURCE_GROUP \
-n $VNET_NAME \
--address-prefix 10.40.0.0/16 \
--subnet-name priv-aca-env-subnet --subnet-prefix 10.40.0.0/23

az network vnet subnet create \
-g $RESOURCE_GROUP \
--vnet-name $VNET_NAME \
-n pub-aca-env-subnet \
--address-prefixes 10.40.2.0/23

az network vnet subnet create \
-g $RESOURCE_GROUP \
--vnet-name $VNET_NAME \
-n jump-subnet \
--address-prefixes 10.40.4.0/23

# Get the subnet resource IDs
PRIV_ACA_ENV_SUBNET_ID=$(az network vnet subnet show -g $RESOURCE_GROUP --vnet-name $VNET_NAME -n priv-aca-env-subnet --query id -o tsv)
PUB_ACA_ENV_SUBNET_ID=$(az network vnet subnet show -g $RESOURCE_GROUP --vnet-name $VNET_NAME -n pub-aca-env-subnet --query id -o tsv)
JUMP_SUBNET_ID=$(az network vnet subnet show -g $RESOURCE_GROUP --vnet-name $VNET_NAME -n jump-subnet --query id -o tsv)
```

### Create the ACA Environment

Creating separate public and private environments for testing purposes

```bash
PRIV_CONTAINERAPPS_ENVIRONMENT=private-aca

az containerapp env create \
--name $PRIV_CONTAINERAPPS_ENVIRONMENT \
--resource-group $RESOURCE_GROUP \
--location $LOCATION \
--internal-only true \
--infrastructure-subnet-resource-id $PRIV_ACA_ENV_SUBNET_ID

PUB_CONTAINERAPPS_ENVIRONMENT=public-aca

az containerapp env create \
  --name $PUB_CONTAINERAPPS_ENVIRONMENT \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION \
  --infrastructure-subnet-resource-id $PUB_ACA_ENV_SUBNET_ID


```

### Deploy an app

```bash
# Deploy an app to the private environment
az containerapp create \
  --name private-container-app \
  --resource-group $RESOURCE_GROUP \
  --environment $PRIV_CONTAINERAPPS_ENVIRONMENT \
  --image mcr.microsoft.com/azuredocs/containerapps-helloworld:latest \
  --target-port 80 \
  --ingress 'external' \
  --query properties.configuration.ingress.fqdn

az containerapp create \
  --name public-container-app \
  --resource-group $RESOURCE_GROUP \
  --environment $PUB_CONTAINERAPPS_ENVIRONMENT \
  --image mcr.microsoft.com/azuredocs/containerapps-helloworld:latest \
  --target-port 80 \
  --ingress 'external' \
  --query properties.configuration.ingress.fqdn
```

### For Private ACA set up the private DNS Zone

```bash
# Get the App FQDN
ENVIRONMENT_DEFAULT_DOMAIN=$(az containerapp env show --name ${PRIV_CONTAINERAPPS_ENVIRONMENT} --resource-group ${RESOURCE_GROUP} --query properties.defaultDomain --out tsv)

# Get the App Private IP
ENVIRONMENT_STATIC_IP=$(az containerapp env show --name ${PRIV_CONTAINERAPPS_ENVIRONMENT} --resource-group ${RESOURCE_GROUP} --query properties.staticIp --out tsv)

# Get the Vnet ID
VNET_ID=$(az network vnet show --resource-group ${RESOURCE_GROUP} --name ${VNET_NAME} --query id --out tsv)

# Create the Private Zone
az network private-dns zone create \
  --resource-group $RESOURCE_GROUP \
  --name $ENVIRONMENT_DEFAULT_DOMAIN

# LInk the Private Zone to the Vnet
az network private-dns link vnet create \
  --resource-group $RESOURCE_GROUP \
  --name $VNET_NAME \
  --virtual-network $VNET_ID \
  --zone-name $ENVIRONMENT_DEFAULT_DOMAIN -e true

# Add the A Record to map the app FQDN to the private IP
az network private-dns record-set a add-record \
  --resource-group $RESOURCE_GROUP \
  --record-set-name "*" \
  --ipv4-address $ENVIRONMENT_STATIC_IP \
  --zone-name $ENVIRONMENT_DEFAULT_DOMAIN
```

### Create a jump vm for testing

```bash
# Create VM Public IP
az network public-ip create \
--resource-group $RESOURCE_GROUP \
--name jump-ip 

# Create the NSG for the jump server
az network nsg create \
--resource-group $RESOURCE_GROUP \
--name jump-nsg

az network nsg rule create \
--resource-group $RESOURCE_GROUP \
--nsg-name jump-nsg \
--name jumpSSH \
--protocol tcp \
--priority 1000 \
--destination-port-range 22 \
--access allow

az network nic create \
--resource-group $RESOURCE_GROUP \
--name jumpNIC \
--vnet-name $VNET_NAME \
--subnet jump-subnet \
--public-ip-address jump-ip \
--network-security-group jump-nsg

az vm create \
--resource-group $RESOURCE_GROUP \
--name jump \
--location $LOCATION \
--nics jumpNIC \
--image UbuntuLTS \
--admin-username azureuser \
--generate-ssh-keys
```
