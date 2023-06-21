# For best results, run this in an Azure cloud (bash) shell.
# This script is heavily based on this repo's README.md and is execution-ready once below variables are set.

# Set variables
# TODO: This is the only configuration you need to make in this script. Naming is based on Cloud Adoption Framework naming standards.
RG=rg-aca-egress-lockdown                       # name of the resource group to contain all assets
LOC=eastus                                      # location of assets
FIREWALLNAME=afw-azure-egress                   # name of the Azure Firewall
VNET_NAME=vnet-aca                              # name of the Azure virtual network
CONTAINER_APP_ENVIRONMENT=acae-egress-lockdown  # name of the Azure Container App Environment
CONTAINER_APP=aca-egresstest                    # name of the Azure Container App from which to test egress
# Optional if you use an ACR and/or AKV (also need to uncomment firewall rules below then)
# AZURE_CONTAINER_REGISTRY=example.azurecr.io     # name of the Azure Container Registry (not used immediately here but likely in your scenario)
# AZURE_KEY_VAULT=example.vault.azure.net         # name of the Azure Key Vault (not used immediately here but suggested for further enhancement)

echo "----------------------------------------------------------------------------------------------------"

# 1) Resource group
echo -e "1/5) Resource group\n"

echo Create the resource group.
az group create -g $RG -l $LOC

# 2) VNet
echo "----------------------------------------------------------------------------------------------------"
echo -e "2/5) Virtual Network\n"

echo Create the virtualnetwork along with the initial subnet for Azure Container Apps.
az network vnet create \
-g $RG \
-n $VNET_NAME \
--address-prefix 10.140.0.0/16 \
--subnet-name aca \
--subnet-prefix 10.140.0.0/27

echo Delegate the subnet to Azure Container App Environment.
az network vnet subnet update \
-g $RG \
-n aca \
--vnet-name $VNET_NAME \
--delegations 'Microsoft.App/environments'

echo Create the subnet for the Azure Firewall.
az network vnet subnet create \
-g $RG \
-n AzureFirewallSubnet \
--vnet-name $VNET_NAME \
--address-prefix 10.140.1.0/24

echo Get the Azure Container App subnet resource ID for later use.
PRIV_ACA_ENV_SUBNET_ID=$(az network vnet subnet show -g $RG --vnet-name $VNET_NAME -n aca --query id -o tsv)

# 3) Firewall
echo "----------------------------------------------------------------------------------------------------"
echo -e "3/5) Firewall\n"

echo Add the Azure Firewall CLI extension.
az extension add -n azure-firewall

echo Create the public IP to be used with the Azure Firewall.
az network public-ip create -g $RG -n pip-azfirewall --sku "Standard"

echo Create the Azure Firewall.
az network firewall create -g $RG -n $FIREWALLNAME --enable-dns-proxy true

echo Configure the Firewall Public IP.
az network firewall ip-config create -g $RG -f $FIREWALLNAME -n aca-firewallconfig --public-ip-address azfirewall-ip --vnet-name $VNET_NAME

# echo Create the application rule for access to the Azure Container Registry.
# az network firewall application-rule create \
# -g $RG \
# -n 'aca-cr' \
# -f $FIREWALLNAME \
# -c 'aca-cr' \
# --source-addresses '*' \
# --protocols 'http=80' 'https=443' \
# --target-fqdns mcr.microsoft.com *.data.mcr.microsoft.com *.blob.core.windows.net \
# --action allow \
# --priority 200

echo Optional: For our demo we will use a docker hub image, so we need to allow Docker Hub access.
az network firewall application-rule create \
-g $RG \
-n 'docker' \
-f $FIREWALLNAME \
-c 'acafwdocker' \
--source-addresses '*' \
--protocols 'http=80' 'https=443' \
--target-fqdns auth.docker.io registry-1.docker.io index.docker.io dseasb33srnrn.cloudfront.net production.cloudflare.docker.com \
--action allow \
--priority 201

echo Optional: For demo purposes we allow access to the icanhazip.com and microsoft.com websites.
az network firewall application-rule create \
-g $RG \
-n 'allowedsites' \
-f $FIREWALLNAME \
-c 'demo' \
--source-addresses '*' \
--protocols 'http=80' 'https=443' \
--target-fqdns icanhazip.com *.microsoft.com \
--action allow \
--priority 202

# TODO: Enable these resources when you are using an Azure Container Registry and/or an Azure Key Vault
# echo Allow access to Azure Container Registry.
# az network firewall application-rule create \
# -g $RG \
# -n 'acr' \
# -f $FIREWALLNAME \
# -c 'acr' \
# --source-addresses '*' \
# --protocols 'http=80' 'https=443' \
# --target-fqdns $AZURE_CONTAINER_REGISTRY *.blob.windows.net \
# --action allow \
# --priority 300

# echo Allow access to Azure Key Vault.
# az network firewall application-rule create \
# -g $RG \
# -n 'akv' \
# -f $FIREWALLNAME \
# -c 'akv' \
# --source-addresses '*' \
# --protocols 'http=80' 'https=443' \
# --target-fqdns $AZURE_KEY_VAULT login.microsoft.com \
# --action allow \
# --priority 301

echo Get the public and private IPs of the Azure Firewall for the routing rules.
FWPUBLIC_IP=$(az network public-ip show -g $RG -n azfirewall-ip --query "ipAddress" -o tsv)
FWPRIVATE_IP=$(az network firewall show -g $RG -n $FIREWALLNAME --query "ipConfigurations[0].privateIPAddress" -o tsv)

echo Create Route Table.
az network route-table create \
-g $RG \
-n udr-aca

echo Create Default Routes.
az network route-table route create \
-g $RG \
-n firewall-route \
--route-table-name udr-aca \
--address-prefix 0.0.0.0/0 \
--next-hop-type VirtualAppliance \
--next-hop-ip-address "$FWPRIVATE_IP"

az network route-table route create \
-g $RG \
-n internet-route \
--route-table-name udr-aca \
--address-prefix $FWPUBLIC_IP/32 \
--next-hop-type Internet

echo Associate the route table to the Azure Container App subnet.
az network vnet subnet update \
-g $RG \
-n aca \
--vnet-name $VNET_NAME \
--route-table udr-aca

# 4) Container App Environment & Container App"
echo "----------------------------------------------------------------------------------------------------"
echo -e "4/5) Container App Environment & Container App\n"

echo Add the Azure Container Apps CLI extension.
az extension add -n containerapp

echo Create the Azure Container App Environment.

az containerapp env create \
-g $RG \
-n $CONTAINER_APP_ENVIRONMENT \
--location $LOC \
--internal-only true \
--logs-destination none \
--enable-workload-profiles \
--infrastructure-subnet-resource-id $PRIV_ACA_ENV_SUBNET_ID

echo Add the container app workload profile.
az containerapp env workload-profile add \
-g $RG \
-n $CONTAINER_APP_ENVIRONMENT \
--min-nodes 1 \
--max-nodes 10 \
--workload-profile-name 'egresslockdown' \
--workload-profile-type 'D4'

echo Add the container app for the egress test container.
az containerapp create \
-g $RG \
-n $CONTAINER_APP \
--environment $CONTAINER_APP_ENVIRONMENT \
--workload-profile-name 'egresslockdown' \
--min-replicas 1 \
--image nginx 

# 5) Testing
echo "----------------------------------------------------------------------------------------------------"
echo -e "5/5) Testing\n"

echo "1) Launch a bash shell inside the $CONTAINER_APP container":
echo -e "   az containerapp exec -n $CONTAINER_APP -g $RG --command 'bash'\n"
echo "2) Execute curl commands against an allowed target:"
echo "   curl -v icanhazip.com"
echo -e "   curl -v www.microsoft.com\n"
echo -e "3) Execute curl commands against any other target to see denied traffic.\n"
