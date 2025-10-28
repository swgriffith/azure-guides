# Anyscale Full Private Setup

## Create Private Network

```bash
# Resource Group Creation
RG=anyscale-private
LOC=northcentralus
az group create -g $RG -l $LOC

# Get the resource group id
RG_ID=$(az group show -g $RG -o tsv --query id)

# Set an environment variable for the VNet name
VNET_NAME=anyscale-vnet

# Create the Vnet along with the initial subet for AKS
az network vnet create \
-g $RG \
-n $VNET_NAME \
--address-prefix 10.140.0.0/16 \
--subnet-name aks \
--subnet-prefix 10.140.0.0/24

# Get a subnet resource ID
VNET_SUBNET_ID=$(az network vnet subnet show -g $RG --vnet-name $VNET_NAME -n aks -o tsv --query id)
```

## Create the Egress Firewall and Route Table

```bash
# Adding a subnet for the Azure Firewall
az network vnet subnet create \
--resource-group $RG \
--vnet-name $VNET_NAME \
--name AzureFirewallSubnet \
--address-prefix 10.140.1.0/24

# Create Azure Firewall Public IP
az network public-ip create -g $RG -n azfirewall-ip --sku "Standard"

# Create Azure Firewall
az extension add --name azure-firewall
FIREWALLNAME=reddog-egress
az network firewall create -g $RG -n $FIREWALLNAME --enable-dns-proxy true

# Configure Firewall IP Config
az network firewall ip-config create -g $RG -f $FIREWALLNAME -n aks-firewallconfig --public-ip-address azfirewall-ip --vnet-name $VNET_NAME

# Apply the Firewall Rules for AKS
az network firewall network-rule create \
-g $RG \
-f $FIREWALLNAME \
--collection-name 'aksfwnr' \
-n 'aksapiudp' \
--protocols 'UDP' \
--source-addresses '*' \
--destination-addresses "AzureCloud.$LOC" \
--destination-ports 1194 --action allow --priority 100

az network firewall network-rule create \
-g $RG \
-f $FIREWALLNAME \
--collection-name 'aksfwnr' \
-n 'aksapitcp' \
--protocols 'TCP' \
--source-addresses '*' \
--destination-addresses "AzureCloud.$LOC" \
--destination-ports 9000 443

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

TARGET_FQDNS=('mcr.microsoft.com' \
'*.data.mcr.microsoft.com' \
'management.azure.com' \
'login.microsoftonline.com' \
'packages.microsoft.com' \
'acs-mirror.azureedge.net')

az network firewall application-rule create \
-g $RG \
-f $FIREWALLNAME \
--collection-name 'aksfwar2' \
-n 'fqdn' \
--source-addresses '*' \
--protocols 'http=80' 'https=443' \
--target-fqdns ${TARGET_FQDNS[@]} \
--action allow --priority 101

az network firewall application-rule create \
-g $RG \
-f $FIREWALLNAME \
--collection-name 'aksfwdocker' \
-n 'docker' \
--source-addresses '*' \
--protocols 'http=80' 'https=443' \
--target-fqdns auth.docker.io registry-1.docker.io index.docker.io dseasb33srnrn.cloudfront.net production.cloudflare.docker.com us-docker.pkg.dev \
--action allow --priority 102


az network firewall application-rule create \
-g $RG \
-f $FIREWALLNAME \
--collection-name 'aksfwkubernetes' \
-n 'k8s' \
--source-addresses '*' \
--protocols 'http=80' 'https=443' \
--target-fqdns registry.k8s.io us-east5-docker.pkg.dev prod-registry-k8s-io-us-east-2.s3.dualstack.us-east-2.amazonaws.com \
--action allow --priority 103

az network firewall application-rule create \
-g $RG \
-f $FIREWALLNAME \
--collection-name 'aksfwanyscale' \
-n 'anyscale' \
--source-addresses '*' \
--protocols 'http=80' 'https=443' \
--target-fqdns console.anyscale.com \
--action allow --priority 104


# First get the public and private IP of the firewall for the routing rules
FWPUBLIC_IP=$(az network public-ip show -g $RG -n azfirewall-ip --query "ipAddress" -o tsv)
FWPRIVATE_IP=$(az network firewall show -g $RG -n $FIREWALLNAME --query "ipConfigurations[0].privateIPAddress" -o tsv)

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

# Associate Route Table to AKS Subnet
az network vnet subnet update \
-g $RG \
--vnet-name $VNET_NAME \
-n aks \
--route-table aksdefaultroutes
```

## Create the Cluster Identities

```bash
# Create a new managed identity
az identity create \
--name clusteridentity \
--resource-group $RG

# Get Managed Identity Resource ID
CLUSTER_IDENTITY_ID=$(az identity show \
--name clusteridentity \
-g $RG \
-o tsv \
--query id)

## NOTE: You may need to wait 30-60 seconds for the identity to propegate before running the next command.
##       If it fails the first time, wait a few seconds and try again.

# Grant the Managed Identity Contributor on the Resource Group
az role assignment create \
--assignee $CLUSTER_IDENTITY_ID \
--role "Contributor" \
--scope "$RG_ID"

# Create a new managed identity
az identity create \
--name kubeletidentity \
--resource-group $RG

KUBELET_IDENTITY_ID=$(az identity show \
--name kubeletidentity \
-g $RG \
-o tsv \
--query id)
```

## Create the AKS Cluster

```bash
# NOTE: Make sure you give your cluster a unique name
CLUSTER_NAME=anyscale-private

# Cluster Creation Command
az aks create \
-g $RG \
-n $CLUSTER_NAME \
--nodepool-name systempool \
--node-vm-size standard_d2s_v5 \
--node-count 1 \
--network-plugin azure \
--network-plugin-mode overlay \
--network-dataplane cilium \
--vnet-subnet-id $VNET_SUBNET_ID \
--pod-cidr 10.244.0.0/16 \
--service-cidr 10.245.0.0/24 \
--dns-service-ip 10.245.0.10 \
--outbound-type UserDefinedRouting \
--enable-managed-identity \
--assign-identity $CLUSTER_IDENTITY_ID \
--assign-kubelet-identity $KUBELET_IDENTITY_ID \
--enable-oidc-issuer \
--enable-workload-identity \
--enable-cluster-autoscaler \
--min-count 1 \
--max-count 3 \
--generate-ssh-keys

# Add a nodepool for anyscale jobs
az aks nodepool add \
-g $RG \
--cluster-name $CLUSTER_NAME \
-n cpu16 \
--node-vm-size "standard_d16s_v5" \
--enable-cluster-autoscaler \
--min-count 0 \
--max-count 10 \
--node-taints "node.anyscale.com/capacity-type=ON_DEMAND:NoSchedule"

# Get the cluster credentials
az aks get-credentials -g $RG -n $CLUSTER_NAME
```

## Install the Ingress Controller

```bash
helm repo add nginx https://kubernetes.github.io/ingress-nginx
helm upgrade ingress-nginx nginx/ingress-nginx \
  --version 4.12.1 \
  --namespace ingress-nginx \
  --values sample-values_nginx.yaml \
  --create-namespace \
  --install
```

# Create the Anyscale Federated Identity

```bash
ANYSCALE_NAMESPACE=anyscale-operator 

# Get the OIDC Issuer URL
export AKS_OIDC_ISSUER="$(az aks show -n $CLUSTER_NAME -g $RG --query "oidcIssuerProfile.issuerUrl" -otsv)"

# Create the managed identity
az identity create --name anyscale-mi --resource-group $RG --location $LOC

# Get identity client ID
export USER_ASSIGNED_CLIENT_ID=$(az identity show --resource-group $RG --name anyscale-mi --query 'clientId' -o tsv)

az identity federated-credential create \
--name anyscale-federated-id \
--identity-name anyscale-mi \
--resource-group $RG \
--issuer ${AKS_OIDC_ISSUER} \
--subject system:serviceaccount:${ANYSCALE_NAMESPACE}:anyscale-operator

```

## Create a Storage Account and Blob Container

```bash
STORAGE_ACCOUNT_NAME=anyscale$RANDOM
STORAGE_CONTAINER_NAME=anyscale-container

# Create a storage account
az storage account create \
  --name $STORAGE_ACCOUNT_NAME \
  --resource-group $RG \
  --location $LOC \
  --sku Standard_LRS

# Create a blob container
az storage container create \
  --name anyscale-container \
  --auth-mode login \
  --account-name $STORAGE_ACCOUNT_NAME

# Get the storage account resource ID
STORAGE_ACCOUNT_ID=$(az storage account show \
  --name $STORAGE_ACCOUNT_NAME \
  --resource-group $RG \
  --query id \
  --output tsv)

# Get the managed identity principal ID
ANYSCALE_MI_PRINCIPAL_ID=$(az identity show \
  --name anyscale-mi \
  --resource-group $RG \
  --query principalId \
  --output tsv)

# Grant Storage Blob Data Contributor role to the managed identity
az role assignment create \
  --role "Storage Blob Data Contributor" \
  --assignee $ANYSCALE_MI_PRINCIPAL_ID \
  --scope $STORAGE_ACCOUNT_ID
```

## Setup Anyscale

```bash
# Anyscale API Key from the portal link above
ANYSCALE_CLI_TOKEN=

ANYSCALE_CLOUD_INSTANCE_NAME=griff-private-cluster

anyscale cloud register \
  --name $ANYSCALE_CLOUD_INSTANCE_NAME \
  --region $LOC \
  --provider azure \
  --compute-stack k8s \
  --cloud-storage-bucket-name "azure://${STORAGE_CONTAINER_NAME}" \
  --cloud-storage-bucket-endpoint "https://${STORAGE_ACCOUNT_NAME}.blob.core.windows.net"


helm repo add anyscale https://anyscale.github.io/helm-charts
helm repo update

# Use the cloudDeploymentId from the output of the anyscale register command you ran above
helm upgrade anyscale-operator anyscale/anyscale-operator \
  --set-string global.cloudDeploymentId= \
  --set-string global.cloudProvider=azure \
  --set-string global.auth.anyscaleCliToken=$ANYSCALE_CLI_TOKEN \
  --set-string workloads.serviceAccount.name=anyscale-operator \
  --namespace $ANYSCALE_NAMESPACE \
  --create-namespace \
  --wait \
  -i

# Get the managed identity client id
MI_CLIENT_ID=$(az identity show -g $RG -n anyscale-mi -o tsv --query clientId)

kubectl patch sa anyscale-operator -n $ANYSCALE_NAMESPACE --type='json' -p="[{"op": "add", "path": "/metadata/annotations/azure.workload.identity~1client-id", "value": "$MI_CLIENT_ID"}]"

kubectl patch sa anyscale-operator -n $ANYSCALE_NAMESPACE --type='json' -p='[{"op": "add", "path": "/metadata/labels/azure.workload.identity~1use", "value": "true"}]'

kubectl rollout restart deploy/anyscale-operator -n $ANYSCALE_NAMESPACE
```
