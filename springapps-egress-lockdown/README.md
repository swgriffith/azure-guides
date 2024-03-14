# Azure Spring Apps Egress Lockdown

In this walk through we'll set up a Vnet and subnet to host an Azure Spring Apps (ASA) Instance. We'll also create an Azure Firewall with the appropriate rules to allow outbound traffic from ASA and then will set up a route table to force the Internet egress traffic for ASA to the firewall. Finally, we'll deploy an app in that environment and test that egress traffic flows through the egress firewall.

## Setup

### Prepare the Vnet

First, lets create the resource group and Vnet. The Vnet will have two subnets. One for ASA and one for the Azure Firewall.

```bash
# Set the Resource Group Name and Region Environment Variables
RG=ASAEgressLockdown
LOC=eastus
ASA_NAME=egresslockasa

# Create Resource Group
az group create -g $RG -l $LOC

# Set an environment variable for the VNet name
VNET_NAME=asa-vnet
ASA_APP_SUBNET_NAME="asa-app-subnet"
ASA_SERVICE_RUNTIME_SUBNET_NAME="asa-service-runtime-subnet"

# Create the Vnet along with the initial subnet for ACA
az network vnet create \
-g $RG \
-n $VNET_NAME \
--address-prefix 10.140.0.0/16 \
--subnet-name $ASA_SERVICE_RUNTIME_SUBNET_NAME \
--subnet-prefix 10.140.0.0/24

# Adding a subnet for the Azure Firewall
az network vnet subnet create \
--resource-group $RG \
--vnet-name $VNET_NAME \
--name $ASA_APP_SUBNET_NAME \
--address-prefix 10.140.1.0/24

# Adding a subnet for the Azure Firewall
az network vnet subnet create \
--resource-group $RG \
--vnet-name $VNET_NAME \
--name AzureFirewallSubnet \
--address-prefix 10.140.2.0/24

```

### Create the Firewall and Route Table

Now lets create the Azure Firewall and the rules required for ASA Egress. After the firewall is created we need to create the route table that will ensure internet traffic is sent to the firewall and attach that route table to the ASA subnet.

```bash
# Create Azure Firewall Public IP
az network public-ip create -g $RG -n azfirewall-ip --sku "Standard"

# Create Azure Firewall
az extension add --name azure-firewall
FIREWALLNAME=reddog-egress
az network firewall create -g $RG -n $FIREWALLNAME --enable-dns-proxy true

# Configure Firewall IP Config
az network firewall ip-config create -g $RG -f $FIREWALLNAME -n asa-firewallconfig --public-ip-address azfirewall-ip --vnet-name $VNET_NAME

# Add firewall network rules.
az network firewall network-rule create \
--resource-group $RG \
--firewall-name $FIREWALLNAME \
--collection-name 'asafwnr' \
--name 'springcloudtcp' \
--protocols 'TCP' \
--source-addresses '*' \
--destination-addresses "AzureCloud" \
--destination-ports 443 445 \
--action allow \
--priority 100

# Add firewall application rules.
az network firewall application-rule create \
--resource-group $RG \
--firewall-name $FIREWALLNAME \
--collection-name 'aksfwar' \
--name 'fqdn' \
--source-addresses '*' \
--protocols 'https=443' \
--fqdn-tags "AzureKubernetesService" \
--action allow \
--priority 100

az network firewall application-rule create \
-g $RG \
-f $FIREWALLNAME \
--collection-name 'aksfwdocker' \
-n 'docker' \
--source-addresses '*' \
--protocols 'http=80' 'https=443' \
--target-fqdns auth.docker.io registry-1.docker.io index.docker.io dseasb33srnrn.cloudfront.net production.cloudflare.docker.com \
--action allow --priority 101

TARGET_FQDNS=('*.digicert.com' \
'*.microsoft.com')

az network firewall application-rule create \
-g $RG \
-f $FIREWALLNAME \
--collection-name 'aksfwarmsft' \
-n 'fqdn' \
--source-addresses '*' \
--protocols 'http=80' 'https=443' \
--target-fqdns ${TARGET_FQDNS[@]} \
--action allow --priority 102

# Get the public and private IP of the firewall for the routing rules
FWPUBLIC_IP=$(az network public-ip show -g $RG -n azfirewall-ip --query "ipAddress" -o tsv)
FWPRIVATE_IP=$(az network firewall show -g $RG -n $FIREWALLNAME --query "ipConfigurations[0].privateIPAddress" -o tsv)

# Create a user-defined route and add a route for Azure Firewall.
az network route-table create --resource-group $RG -l $LOC --name asadefaultroutes-app

az network route-table route create \
--resource-group $RG \
--name firewall-route \
--route-table-name asadefaultroutes-app \
--address-prefix 0.0.0.0/0 \
--next-hop-type VirtualAppliance \
--next-hop-ip-address $FWPRIVATE_IP

az network route-table create --resource-group $RG -l $LOC --name asadefaultroutes-svc

az network route-table route create \
--resource-group $RG \
--name firewall-route \
--route-table-name asadefaultroutes-svc \
--address-prefix 0.0.0.0/0 \
--next-hop-type VirtualAppliance \
--next-hop-ip-address $FWPRIVATE_IP

# Associate Route Table to ASA Subnets
az network vnet subnet update \
-g $RG \
--vnet-name $VNET_NAME \
-n $ASA_SERVICE_RUNTIME_SUBNET_NAME \
--route-table asadefaultroutes-svc

az network vnet subnet update \
-g $RG \
--vnet-name $VNET_NAME \
-n $ASA_APP_SUBNET_NAME \
--route-table asadefaultroutes-app
```

### Add roles for ASA Resource Provider

```bash
export VIRTUAL_NETWORK_RESOURCE_ID=$(az network vnet show --name $VNET_NAME --resource-group $RG --query "id" --output tsv)

#TODO: Revisit these rights
az role assignment create --role "Owner" --scope ${VIRTUAL_NETWORK_RESOURCE_ID} --assignee e8de9221-a19c-4c81-b814-fd37c6caf9d2

export APP_ROUTE_TABLE_RESOURCE_ID=$(az network route-table show --name asadefaultroutes-app --resource-group $RG --query "id" --output tsv)

#TODO: Revisit these rights    
az role assignment create --role "Owner" --scope ${APP_ROUTE_TABLE_RESOURCE_ID} --assignee e8de9221-a19c-4c81-b814-fd37c6caf9d2

export SERVICE_ROUTE_TABLE_RESOURCE_ID=$(az network route-table show --name asadefaultroutes-svc --resource-group $RG --query "id" --output tsv)

#TODO: Revisit these rights    
az role assignment create --role "Owner" --scope ${SERVICE_ROUTE_TABLE_RESOURCE_ID} --assignee e8de9221-a19c-4c81-b814-fd37c6caf9d2
```

### Create the ASA Environment

```bash
az spring create \
--name $ASA_NAME \
--resource-group $RG \
--vnet $VNET_NAME \
--app-subnet $ASA_APP_SUBNET_NAME \
--service-runtime-subnet $ASA_SERVICE_RUNTIME_SUBNET_NAME \
--outbound-type userDefinedRouting
```

### Create a test spring app

Finally, lets create a test app and run a call to check the egress ip. We should see that the egress IP matches the Azure Firewall public IP.

```bash

# az spring app deploy \
# --resource-group $RG \
# --name $ASA_NAME \
# --container-image nginx \
# --service nginx-test
```

