RG=EphPrivateSFTP
LOC=eastus
SANAME=griffithsa
VNET_NAME=acivnet
SUBNET_NAME=aci
SFTPUSER=griffith
SFTPPASSWD=LetMeIn1234
FIREWALLNAME=demofirewall
ALB_NAME=sftplb

# Create Resource Group
az group create -n $RG -l $LOC

# Create Storage Account for Azure File Share
az storage account create \
    --resource-group $RG \
    --name $SANAME \
    --location $LOC \
    --kind StorageV2 \
    --sku Standard_LRS \
    --enable-large-file-share 

# Get Storage Account Key
storageAccountKey=$(az storage account keys list -g $RG -n $SANAME --query '[0].value' -o tsv)

# Create Azure Files Share
az storage share create \
    --account-name $SANAME \
    --account-key $storageAccountKey \
    --name sftproot \
    --quota 1024 



# Create Vnet
az network vnet create \
-g $RG \
-n $VNET_NAME \
--address-prefix 10.40.0.0/16 \
--subnet-name $SUBNET_NAME --subnet-prefix 10.40.0.0/24

# Get Vnet ID for later use
VNET_ID=$(az network vnet show -g $RG -n $VNET_NAME --query id -o tsv)

# Create Azure Firewall Subnet
az network vnet subnet create \
    --resource-group $RG \
    --vnet-name $VNET_NAME \
    --name AzureFirewallSubnet \
    --address-prefix 10.40.1.0/24

# Get the subnet id
SUBNET_ID=$(az network vnet show -g $RG -n acivnet -o tsv --query "subnets[?name=='aci'].id")

# Create SFTP Server Container Instance
az container create \
--name sftp \
--resource-group $RG \
--image atmoz/sftp:latest \
--vnet $VNET_NAME \
--subnet $SUBNET_NAME \
--environment-variables "SFTP_USERS=$SFTPUSER:$SFTPPASSWD:1001" \
--ports 22 #\
# Still working on Azure files permissions issues
#--azure-file-volume-account-name $SANAME \
#--azure-file-volume-account-key $storageAccountKey \
#--azure-file-volume-share-name sftproot \
#--azure-file-volume-mount-path /home/$SFTPUSER

# Grant the user ownership of the share
az container exec -g $RG -n sftp --exec-command "chown -R griffith /home/$SFTPUSER"

# Get Container IP for later use
SFTP_IP=$(az container show -g $RG -n sftp --query 'ipAddress.ip' -o tsv)

# Create Azure Firewall Public IP
az network public-ip create -g $RG -n azfirewall-ip -l $LOC --sku "Standard" --zone 1

# Create Azure Firewall
az extension add --name azure-firewall
az network firewall create -g $RG -n $FIREWALLNAME -l $LOC --enable-dns-proxy true

# Configure Firewall IP Config
az network firewall ip-config create -g $RG -f $FIREWALLNAME -n aci-firewallconfig --public-ip-address azfirewall-ip --vnet-name $VNET_NAME


# Capture Firewall IP Address for Later Use
FWPUBLIC_IP=$(az network public-ip show -g $RG -n azfirewall-ip --query "ipAddress" -o tsv)
FWPRIVATE_IP=$(az network firewall show -g $RG -n $FIREWALLNAME --query "ipConfigurations[0].privateIpAddress" -o tsv)

# Create inbound NAT rule
az network firewall nat-rule create \
--collection-name sftp \
--source-addresses "*" \
--destination-addresses $FWPUBLIC_IP \
--destination-ports 22 \
--firewall-name $FIREWALLNAME \
--name "Allow SFTP" \
--protocols Any \
--resource-group $RG \
--translated-port 22 \
--translated-address $SFTP_IP \
--priority 100 \
--action "Dnat"

echo "Connect with: sftp $SFTPUSER@$FWPUBLIC_IP"