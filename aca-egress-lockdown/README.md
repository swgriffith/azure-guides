# ACA Egress Lockdown

In this walk through we'll set up a Vnet and subnet to host an Azure Container App (ACA). We'll also create an Azure Firewall with the appropriate rules to allow outbound traffic from ACA and then will set up a route table to force the Internet egress traffic for ACA to the firewall. Finally, we'll create a container app in that environment and test that egress traffic flows through the egress firewall.

## Setup

### Prepare the Vnet

First, lets create the resource group and Vnet. The Vnet will have two subnets. One for ACA and one for the Azure Firewall.

```bash
# Set the Resource Group Name and Region Environment Variables
RG=ACAEgressLockdown2
LOC=eastus

# Create Resource Group
az group create -g $RG -l $LOC

# Set an environment variable for the VNet name
VNET_NAME=aca-vnet

# Create the Vnet along with the initial subet for ACA
az network vnet create \
-g $RG \
-n $VNET_NAME \
--address-prefix 10.140.0.0/16 \
--subnet-name aca \
--subnet-prefix 10.140.0.0/27

az network vnet subnet update \
--resource-group $RG \
--vnet-name $VNET_NAME \
--name aca \
--delegations 'Microsoft.App/environments'

# Adding a subnet for the Azure Firewall
az network vnet subnet create \
--resource-group $RG \
--vnet-name $VNET_NAME \
--name AzureFirewallSubnet \
--address-prefix 10.140.1.0/24

# Get the ACA Subnet Resource ID for later use
PRIV_ACA_ENV_SUBNET_ID=$(az network vnet subnet show -g $RG --vnet-name $VNET_NAME -n aca --query id -o tsv)
```

### Create the Firewall and Route Table

Now lets create the Azure Firewall and the rules required for ACA Egress.

```bash
# Create Azure Firewall Public IP
az network public-ip create -g $RG -n azfirewall-ip --sku "Standard"

# Create Azure Firewall
az extension add --name azure-firewall
FIREWALLNAME=reddog-egress
az network firewall create -g $RG -n $FIREWALLNAME --enable-dns-proxy true

# Configure Firewall IP Config
az network firewall ip-config create -g $RG -f $FIREWALLNAME -n aca-firewallconfig --public-ip-address azfirewall-ip --vnet-name $VNET_NAME

# Create list of FQDNs for the rule
TARGET_FQDNS=('mcr.microsoft.com' \
'*.data.mcr.microsoft.com' \
'*.blob.core.windows.net')

# Create the application rule for ACA Container Registry Access
az network firewall application-rule create \
-g $RG \
-f $FIREWALLNAME \
--collection-name 'aca-cr' \
-n 'aca-cr' \
--source-addresses '*' \
--protocols 'http=80' 'https=443' \
--target-fqdns $TARGET_FQDNS[@] \
--action allow --priority 200

# Optional: 
# For our demo we'll use a docker hub image, so we need to allow Docker Hub access
az network firewall application-rule create \
-g $RG \
-f $FIREWALLNAME \
--collection-name 'acafwdocker' \
-n 'docker' \
--source-addresses '*' \
--protocols 'http=80' 'https=443' \
--target-fqdns auth.docker.io registry-1.docker.io index.docker.io dseasb33srnrn.cloudfront.net production.cloudflare.docker.com \
--action allow --priority 201

# Just for demo purposes we'll also add icanhazip.com
az network firewall application-rule create \
-g $RG \
-f $FIREWALLNAME \
--collection-name 'demo' \
-n 'icanhazip' \
--source-addresses '*' \
--protocols 'http=80' 'https=443' \
--target-fqdns icanhazip.com \
--action allow --priority 202

# Get the public and private IP of the firewall for the routing rules
FWPUBLIC_IP=$(az network public-ip show -g $RG -n azfirewall-ip --query "ipAddress" -o tsv)
FWPRIVATE_IP=$(az network firewall show -g $RG -n $FIREWALLNAME --query "ipConfigurations[0].privateIPAddress" -o tsv)

# Create Route Table
az network route-table create \
-g $RG \
-n acadefaultroutes

# Create Default Routes
az network route-table route create \
-g $RG \
--route-table-name acadefaultroutes \
-n firewall-route \
--address-prefix 0.0.0.0/0 \
--next-hop-type VirtualAppliance \
--next-hop-ip-address $FWPRIVATE_IP

az network route-table route create \
-g $RG \
--route-table-name acadefaultroutes \
-n internet-route \
--address-prefix $FWPUBLIC_IP/32 \
--next-hop-type Internet

# Associate Route Table to ACA Subnet
az network vnet subnet update \
-g $RG \
--vnet-name $VNET_NAME \
-n aca \
--route-table acadefaultroutes
```

### Create the ACA Environment

```bash
# Create the container app environment
PRIV_CONTAINERAPPS_ENVIRONMENT=private-aca

az containerapp env create \
--name $PRIV_CONTAINERAPPS_ENVIRONMENT \
--resource-group $RG \
--location $LOC \
--internal-only true \
--logs-destination none \
--enable-workload-profiles \
--infrastructure-subnet-resource-id $PRIV_ACA_ENV_SUBNET_ID

# Add the container app workload profile
az containerapp env workload-profile add \
--name $PRIV_CONTAINERAPPS_ENVIRONMENT \
--resource-group $RG \
--min-nodes 1 \
--max-nodes 10 \
--workload-profile-name 'egresslockdown' \
--workload-profile-type 'D4'
```

### Create an egress test container app

Finally, lets create a test app and run a call to check the egress ip. We should see that the egress IP matches the Azure Firewall public IP.

```bash
az containerapp create \
--name egresstest-container-app \
--resource-group $RG \
--environment $PRIV_CONTAINERAPPS_ENVIRONMENT \
--workload-profile-name 'egresslockdown' \
--min-replicas 1 \
--image nginx 
```

Give the above deployed application a minute to come online and then follow the steps below to test.

```bash
# Check the Azure Firewall public IP 
echo FirewallIP: $FWPUBLIC_IP

# Sample output
FirewallIP: 40.117.35.162

# Exec into the container app so we can run some commands
az containerapp exec -n egresstest-container-app -g $RG --command 'bash'

# In the container terminal run the following
curl icanhazip.com

# The ip returned should match the firewall egress ip above
```