# AKS Multi-Cluster Blue/Green Example

## Setup

```bash
RG=BlueGreenLab
LOC=eastus2
CLUSTER_A_NAME=cluster-a
CLUSTER_B_NAME=cluster-b

# Create the resource group
az group create -n $RG -l $LOC

# Set an environment variable for the VNet name
VNET_NAME=lab-vnet
VNET_ADDRESS_SPACE=10.140.0.0/16
AKS_CLUSTER_A_SUBNET_ADDRESS_SPACE=10.140.0.0/24
AKS_CLUSTER_B_SUBNET_ADDRESS_SPACE=10.140.1.0/24
AKS_CLUSTER_A_LB_SUBNET_ADDRESS_SPACE=10.140.5.0/24
AKS_CLUSTER_B_LB_SUBNET_ADDRESS_SPACE=10.140.6.0/24

# Create the Vnet along with the initial subet for AKS
az network vnet create \
-g $RG \
-n $VNET_NAME \
--address-prefix $VNET_ADDRESS_SPACE \
--subnet-name aks-cluster-a-nodes \
--subnet-prefix $AKS_CLUSTER_A_SUBNET_ADDRESS_SPACE

VNET_ID=$(az network vnet show -g $RG -n $VNET_NAME --query id -o tsv)

# Add a new subnet for the load balancer
az network vnet subnet create \
-g $RG \
--vnet-name $VNET_NAME \
--name aks-cluster-b-nodes \
--address-prefix $AKS_CLUSTER_B_SUBNET_ADDRESS_SPACE

# Add a new subnet for the load balancer
az network vnet subnet create \
-g $RG \
--vnet-name $VNET_NAME \
--name aks-cluster-a-loadbalancer \
--address-prefix $AKS_CLUSTER_A_LB_SUBNET_ADDRESS_SPACE

az network vnet subnet create \
-g $RG \
--vnet-name $VNET_NAME \
--name aks-cluster-b-loadbalancer \
--address-prefix $AKS_CLUSTER_B_LB_SUBNET_ADDRESS_SPACE

# Create two AKS Clusters
# First get the vnet/subnet resource IDs for the clusers
CLUSTER_A_VNET_SUBNET_ID=$(az network vnet subnet show -g $RG --vnet-name $VNET_NAME -n aks-cluster-a-nodes -o tsv --query id)

CLUSTER_B_VNET_SUBNET_ID=$(az network vnet subnet show -g $RG --vnet-name $VNET_NAME -n aks-cluster-b-nodes -o tsv --query id)

# Create Cluster A
az aks create -g $RG -n $CLUSTER_A_NAME -c 1 --vnet-subnet-id $CLUSTER_A_VNET_SUBNET_ID

# Create Cluster B
az aks create -g $RG -n $CLUSTER_B_NAME -c 1 --vnet-subnet-id $CLUSTER_B_VNET_SUBNET_ID

# Get Cluster Credentials
az aks get-credentials -g $RG -n $CLUSTER_A_NAME
az aks get-credentials -g $RG -n $CLUSTER_B_NAME
```

## Set up cluster rights

For AKS to deploy to a subnet other than it's own, it needs read and join rights on that subnet. We'll simplify by using 'Network Contributor'.

```bash
# Get the cluster managed identities
CLUSTER_A_IDENTITY=$(az aks show -g $RG -n $CLUSTER_A_NAME -o tsv --query identity.principalId)
CLUSTER_B_IDENTITY=$(az aks show -g $RG -n $CLUSTER_B_NAME -o tsv --query identity.principalId)

# Grant cluster A rights to its loadbalancer subnet
az role assignment create \
--role "Network Contributor" \
--assignee $CLUSTER_A_IDENTITY \
--scope $VNET_ID

# Grant cluster B rights to its loadbalancer subnet
az role assignment create \
--role "Network Contributor" \
--assignee $CLUSTER_B_IDENTITY \
--scope $VNET_ID
```

## Deploy Sample Apps

### Cluster A

```bash
# Make sure your connected to the right cluster
kubectl config use-context $CLUSTER_A_NAME
kubectl config get-contexts

# Deploy a sample app with the cluster name embedded
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: aks-${CLUSTER_A_NAME}-helloworld
spec:
  replicas: 3
  selector:
    matchLabels:
      app: aks-${CLUSTER_A_NAME}-helloworld
  template:
    metadata:
      labels:
        app: aks-${CLUSTER_A_NAME}-helloworld
    spec:
      containers:
      - name: aks-helloworld
        image: cilium/echoserver
        ports:
        - containerPort: 8080
        env:
        - name: PORT
          value: '8080'
EOF
```

We want the kubernetes service to use a private load balancer, in the subnet we designated for cluster A and we want it to use a static IP. 

```bash
# Choose an IP from your Cluster A Load Balancer Subnet
CLUSTER_A_KUBE_SVC_STATIC_IP=10.140.5.10

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: aks-${CLUSTER_A_NAME}-helloworld-svc
  annotations:
    service.beta.kubernetes.io/azure-load-balancer-internal: "true"
    service.beta.kubernetes.io/azure-load-balancer-internal-subnet: aks-cluster-a-loadbalancer
    service.beta.kubernetes.io/azure-load-balancer-ipv4: ${CLUSTER_A_KUBE_SVC_STATIC_IP}
spec:
  type: LoadBalancer
  ports:
  - port: 80
    targetPort: 8080
  selector:
    app: aks-${CLUSTER_A_NAME}-helloworld
EOF
```

### Cluster B

```bash
# Make sure your connected to the right cluster
kubectl config use-context $CLUSTER_B_NAME
kubectl config get-contexts

# Deploy a sample app with the cluster name embedded
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: aks-${CLUSTER_B_NAME}-helloworld
spec:
  replicas: 3
  selector:
    matchLabels:
      app: aks-${CLUSTER_B_NAME}-helloworld
  template:
    metadata:
      labels:
        app: aks-${CLUSTER_B_NAME}-helloworld
    spec:
      containers:
      - name: aks-helloworld
        image: cilium/echoserver
        ports:
        - containerPort: 8080
        env:
        - name: PORT
          value: '8080'
EOF
```

As with above, we'll select a static IP from the loadbalancer subnet and deploy

```bash
# Choose an IP from your Cluster B Load Balancer Subnet
CLUSTER_B_KUBE_SVC_STATIC_IP=10.140.6.10

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: aks-${CLUSTER_B_NAME}-helloworld-svc
  annotations:
    service.beta.kubernetes.io/azure-load-balancer-internal: "true"
    service.beta.kubernetes.io/azure-load-balancer-internal-subnet: aks-cluster-b-loadbalancer
    service.beta.kubernetes.io/azure-load-balancer-ipv4: ${CLUSTER_B_KUBE_SVC_STATIC_IP}
spec:
  type: LoadBalancer
  ports:
  - port: 80
    targetPort: 8080
  selector:
    app: aks-${CLUSTER_B_NAME}-helloworld
EOF
```

## Show the loadbalancer assigned subnet

```bash
# Get the managed cluster resource group
AKS_CLUSTER_A_MC_RG=$(az aks show -g $RG -n $CLUSTER_A_NAME -o tsv --query nodeResourceGroup)
AKS_CLUSTER_B_MC_RG=$(az aks show -g $RG -n $CLUSTER_B_NAME -o tsv --query nodeResourceGroup)

az network lb show \
--resource-group $AKS_CLUSTER_A_MC_RG \
--name kubernetes-internal \
--query "frontendIPConfigurations[0].subnet" \
--output tsv

az network lb show \
--resource-group $AKS_CLUSTER_B_MC_RG \
--name kubernetes-internal \
--query "frontendIPConfigurations[0].subnet" \
--output tsv
```

## Add an Azure Application Gateway

```bash
# Add a subnet for the Azure App Gateway
APP_GW_SUBNET_ADDRESS_SPACE=10.140.7.0/24

# Since we'll be allowing internet access to this Application Gateway, we should create and apply a network security group
# to the Application Gateway subnet
az network nsg create --resource-group $RG --name app-gw-subnet-nsg

# Get my IP
MY_IP=$(curl ipv4.icanhazip.com)

# Create the NSG rule
az network nsg rule create \
--resource-group $RG \
--nsg-name app-gw-subnet-nsg \
--name AllowHTTP \
--protocol Tcp \
--direction Inbound \
--priority 100 \
--source-address-prefixes $MY_IP \
--source-port-ranges '*' \
--destination-address-prefixes '*' \
--destination-port-ranges 80 \
--access Allow

# Create the Mandatory Gateway Manager rule
az network nsg rule create \
--resource-group $RG \
--nsg-name app-gw-subnet-nsg \
--name AllowGatewayManager \
--protocol '*' \
--direction Inbound \
--priority 2702 \
--source-address-prefixes "GatewayManager" \
--destination-port-range '65200-65535' \
--access Allow

az network nsg rule create -g MyResourceGroup --nsg-name MyNsg -n MyNsgRuleWithTags --priority 400 --source-address-prefixes VirtualNetwork --destination-address-prefixes Storage --destination-port-ranges '65200-65535' --direction Outbound --access Allow --protocol Tcp --description "Allow VirtualNetwork to Storage."

az network vnet subnet create \
-g $RG \
--vnet-name $VNET_NAME \
--name app-gw-subnet \
--address-prefix $APP_GW_SUBNET_ADDRESS_SPACE \
--nsg app-gw-subnet-nsg

# Create and app gateway public IP
az network public-ip create --name app-gw-pip --resource-group $RG --sku Standard

az network application-gateway create \
--name app-gw \
--resource-group $RG \
--capacity 2 \
--sku Standard_v2 \
--public-ip-address app-gw-pip \
--vnet-name $VNET_NAME \
--subnet app-gw-subnet \
--servers "$CLUSTER_A_KUBE_SVC_STATIC_IP" "$CLUSTER_B_KUBE_SVC_STATIC_IP" \
--priority 100

# Get the App GW Public IP
APP_GW_PUBLIC_IP=$(az network public-ip show --name app-gw-pip --resource-group $RG -o tsv --query ipAddress)

curl http://${APP_GW_PUBLIC_IP}
```