# Using App Gateway for Containers with Egress Lockdown

This walkthrough demonstates the setup of the new Azure App Gateway for Containers (hereafter AGC) managed ingress controller on a cluster configured with egress traffic forced to an Azure Firewall and with the cluster configured with outboundType Route Table.

## Setup

For this setup we'll need to create the following:

- Resource Group
- Vnet with subnets for the Firewall, AGC and AKS Cluster
- Azure Firewall
- Firewall Rules needed for AKS to function
- Route Table with Default Route (0.0.0.0/0) to the firewall
- AKS Cluster
- AGC
- Test app deployed to the cluster
- Gateway Instance
- HTTP Route


### Resource Group and Vnet

First create the Resource Group and virtual network we'll use for the deployment. We'll also create the subnet that the Azure Firewall will use, since we'll be deploying that next.

```bash
# Resource Group Creation
RG=EphAGCEgressLock2
LOC=eastus
az group create -g $RG -l $LOC

# Get the resource group id
RG_ID=$(az group show -g $RG -o tsv --query id)

# Set an environment variable for the VNet name
VNET_NAME=reddog-vnet

# Create the Vnet along with the initial subet for AKS
az network vnet create \
-g $RG \
-n $VNET_NAME \
--address-prefix 10.140.0.0/16 \
--subnet-name aks \
--subnet-prefix 10.140.0.0/24

# Get a subnet resource ID
VNET_SUBNET_ID=$(az network vnet subnet show -g $RG --vnet-name $VNET_NAME -n aks -o tsv --query id)

# Adding a subnet for the Azure Firewall
az network vnet subnet create \
--resource-group $RG \
--vnet-name $VNET_NAME \
--name AzureFirewallSubnet \
--address-prefix 10.140.1.0/24
```

### Firewall

Now to create the Azure Firewall.

```bash
# Create Azure Firewall Public IP
az network public-ip create -g $RG -n azfirewall-ip --sku "Standard"

# Create Azure Firewall
az extension add --name azure-firewall
FIREWALLNAME=reddog-egress
az network firewall create -g $RG -n $FIREWALLNAME --enable-dns-proxy true

# Configure Firewall IP Config
az network firewall ip-config create -g $RG -f $FIREWALLNAME -n aks-firewallconfig --public-ip-address azfirewall-ip --vnet-name $VNET_NAME

```

### Firewall Rules

With the firewall created, we'll add the rules needed to ensure AKS can operate. You can add additional rules here as needed.

```bash
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
--target-fqdns $TARGET_FQDNS[@] \
--action allow --priority 101
```


### Route Table

With the firewall created, we'll set up the route table to ensure that egress traffic is sent to the firewall and then we'll attach this route table to the AKS cluster subnet.

```bash
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

### Cluster Creation

Next we'll create the AKS Cluster. We'll set this up with a single node, for testing purposes and will enable outboundType for userDefinedRouting. We'll also enable the OIDC Issuer and workload identity, as they're used by AGC later.

> **NOTE:** At this time, AGC only supports Azure CNI in standard mode, not in 'Overlay' mode. If you try another option here it will not work.

```bash
# NOTE: Make sure you give your cluster a unique name
CLUSTER_NAME=acglab

# Cluster Creation Command
az aks create \
-g $RG \
-n $CLUSTER_NAME \
--nodepool-name systempool \
--node-vm-size Standard_D2_v4 \
--node-count 1 \
--network-plugin azure \
--network-policy calico \
--vnet-subnet-id $VNET_SUBNET_ID \
--outbound-type userDefinedRouting \
--enable-managed-identity \
--enable-oidc-issuer \
--enable-workload-identity 

# Grab the cluster credentials
az aks get-credentials -g $RG -n $CLUSTER_NAME
```

### Setup App Gateway for Containers

Now that our cluster is working we can add a new subnet for the AGC and run through all the steps for setting up the application controler, based on the setup guide [here](https://learn.microsoft.com/en-us/azure/application-gateway/for-containers/quickstart-deploy-application-gateway-for-containers-alb-controller?tabs=install-helm-windows). That involved getting the subnet ID and Managed Cluster ID, creating a managed Identity, federating that managed identity with a Kubernetes Service Account, granting the identity the rights documented in the product setup and then finally installing the Application Load Balancer controller via Helm.

```bash
# Create the AGC subnet
az network vnet subnet create \
--resource-group $RG \
--vnet-name $VNET_NAME \
--name subnet-alb \
--address-prefixes 10.140.2.0/24 \
--delegations 'Microsoft.ServiceNetworking/trafficControllers'

# Get the AGC Subnet ID
ALB_SUBNET_ID=$(az network vnet subnet show --name subnet-alb --resource-group $RG --vnet-name $VNET_NAME --query '[id]' --output tsv)

# Get the Managed Cluster Resource Group and ID
MC_RG=$(az aks show --resource-group $RG --name $CLUSTER_NAME --query "nodeResourceGroup" -o tsv)
MC_RG_ID=$(az group show --name $MC_RG --query id -otsv)

# Create a new managed identity and get its principal ID
IDENTITY_RESOURCE_NAME='azure-alb-identity'
az identity create --resource-group $RG --name $IDENTITY_RESOURCE_NAME
PRINCIPAL_ID="$(az identity show -g $RG -n $IDENTITY_RESOURCE_NAME --query principalId -otsv)"

# Assign the managed identity reader rights on the managed cluster resource group
az role assignment create --assignee-object-id $PRINCIPAL_ID --assignee-principal-type ServicePrincipal --scope $MC_RG_ID --role "acdd72a7-3385-48ef-bd42-f606fba81ae7" # Reader role

# Get the OIDC Issuer Name and federate a service account, which will be created later, with the managed identity we created above
AKS_OIDC_ISSUER="$(az aks show -n "$CLUSTER_NAME" -g "$RG" --query "oidcIssuerProfile.issuerUrl" -o tsv)"

az identity federated-credential create --name "azure-alb-identity" \
--identity-name "$IDENTITY_RESOURCE_NAME" \
--resource-group $RG \
--issuer "$AKS_OIDC_ISSUER" \
--subject "system:serviceaccount:azure-alb-system:alb-controller-sa"

# Install the Application Load Balancer for AGC via Helm
helm install alb-controller oci://mcr.microsoft.com/application-lb/charts/alb-controller \
--version 0.4.023971 \
--set albController.podIdentity.clientID=$(az identity show -g $RG -n azure-alb-identity --query clientId -o tsv)

# Verify that the pods start and check that the gateway setup completed successfully
watch kubectl get pods -n azure-alb-system
kubectl get gatewayclass azure-alb-external -o yaml
```

### Deploy the Application LoadBalancer Instance

With the Application Load Balancer Controller running, we now want to create an instance of the ALB in Kubernetes. We'll need to give the managed identity some additional rights.

```bash
# Delegate AppGw for Containers Configuration Manager role to AKS Managed Cluster RG
az role assignment create --assignee-object-id $PRINCIPAL_ID --assignee-principal-type ServicePrincipal --scope $MC_RG_ID --role "fbc52c3f-28ad-4303-a892-8a056630b8f1"  
# Delegate Network Contributor permission for join to association subnet
az role assignment create --assignee-object-id $PRINCIPAL_ID --assignee-principal-type ServicePrincipal --scope $ALB_SUBNET_ID --role "4d97b98b-1d4f-4787-a291-c67834d212e7" 

# Create the instance of the Application Load Balancer in the cluster.
kubectl apply -f - <<EOF
apiVersion: alb.networking.azure.io/v1
kind: ApplicationLoadBalancer
metadata:
  name: alb-test
spec:
  associations:
  - $ALB_SUBNET_ID
EOF

# Monitor the state of the ALB Setup until it's ready
kubectl get applicationloadbalancer alb-test -o yaml -w
```

### Deploy the test app

Now that we have the environment all set up we can deploy a simple test app, gateway and http-route. For this, we'll test TLS offload, so we'll upload a self signed certificate as a secret and used that for the application ingress over https.

```bash
# Deploy the test application
kubectl apply -f testapp.yaml

# Create the TLS Secret and Gateway config
kubectl apply -f gateway.yaml

# Create the http route
kubectl apply -f http-route.yaml

# Get the FQDN for the gateway
FQDN=$(kubectl get gateway gateway-01 -o jsonpath='{.status.addresses[0].value}')

# Run a test curl to ensure you get a response
curl --insecure https://$FQDN/
```