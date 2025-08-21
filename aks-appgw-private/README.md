# AKS App Gateway Private

## Setup

In the following we'll set up a new virtual network, AKS Cluster with managed internal ingress and a private Azure App Gateway. 

Let's start by setting some environment variables.

```bash
RG=EphAppGW
LOC=eastus2
CLUSTER_NAME=democluster
VNET_NAME=reddog-vnet
```

Now we'll create the resource group and virtual network. We'll also grab the fully qualified resource ID of the subnet were our AKS cluster will be deployed.

```bash
# Create the Resource Group
az group create -g $RG -l $LOC

# Get the resource group id
RG_ID=$(az group show -g $RG -o tsv --query id)

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


```bash
# Create the cluster with AKS App Routing for private nginx ingress
az aks create \
-g $RG \
-n $CLUSTER_NAME \
--vnet-subnet-id $VNET_SUBNET_ID \
--network-plugin azure \
--network-plugin-mode overlay \
--network-dataplane cilium \
--enable-app-routing \
--app-routing-default-nginx-controller Internal

# Get the cluster credentials
az aks get-credentials -g $RG -n $CLUSTER_NAME

# Check the status of the private managed ingress
kubectl get svc,pods -n app-routing-system

```

We'll deploy a test workload

```bash
# Deploy the application and service
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: aks-helloworld
spec:
  replicas: 1
  selector:
    matchLabels:
      app: aks-helloworld
  template:
    metadata:
      labels:
        app: aks-helloworld
    spec:
      containers:
      - name: aks-helloworld
        image: cilium/echoserver:1.10.3
        ports:
        - containerPort: 8080
        env:
        - name: PORT
          value: '8080'
---
apiVersion: v1
kind: Service
metadata:
  name: aks-helloworld
spec:
  type: ClusterIP
  ports:
  - port: 8080
  selector:
    app: aks-helloworld
EOF

cat <<EOF|kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: aks-helloworld
  namespace: default
spec:
  ingressClassName: webapprouting.kubernetes.azure.com
  rules:
  - http:
      paths:
      - backend:
          service:
            name: aks-helloworld
            port:
              number: 8080
        path: /hello-world
        pathType: Prefix
EOF

# Get the ingress private ip
INGRESS_PRIVATE_IP=$(kubectl get svc nginx -n app-routing-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
```

Now lets provision the private Azure Application Gateway

```bash
# Create a dedicated subnet for Application Gateway
az network vnet subnet create \
    -g $RG \
    --vnet-name $VNET_NAME \
    -n appgw \
    --delegations Microsoft.Network/applicationGateways \
    --address-prefix 10.140.1.0/24

# (Optional) Grab the subnet resource id
APPGW_SUBNET_ID=$(az network vnet subnet show -g $RG --vnet-name $VNET_NAME -n appgw -o tsv --query id)

# Create an internal (private) Application Gateway (Standard_v2)
az network application-gateway create \
-g $RG \
-n appgw \
--location $LOC \
--sku Standard_v2 \
--min-capacity 0 \
--max-capacity 2 \
--priority 1000 \
--vnet-name $VNET_NAME \
--subnet appgw \
--private-ip-address 10.140.1.4 \
--servers "$INGRESS_PRIVATE_IP"

# Create a health probe that hits a valid path on the 
# ingress controller
az network application-gateway probe create \
-g $RG \
--gateway-name appgw \
-n demo-probe \
--protocol http \
--host 127.0.0.1 \
--path "/hello-world"

# Verify provisioning state and private frontend IP
az network application-gateway show -g $RG -n appgw -o table
az network application-gateway frontend-ip list -g $RG --gateway-name appgw -o table
```