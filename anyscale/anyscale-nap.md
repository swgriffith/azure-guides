# Using Anyscale with Node Autoprovisioning

In this walkthrough we'll set up Anyscale on an AKS cluster and enable autoscaling via [Node Auto Provisioner (aka Karpenter)](https://learn.microsoft.com/en-us/azure/aks/node-auto-provisioning)

## Cluster Setup

First we'll set up some environment variables to be used through the rest of the delpoyment commands.

```bash
# Name of the resource group we will create
RESOURCE_GROUP=anyscale-nap-lab
# Azure Region where we will deploy
LOCATION=northcentralus
# Name of the Virtual Network we'll create
VNET_NAME=anyscale-vnet
# Name of the AKS cluster to be created
CLUSTER_NAME=anyscale-aks
# Name of the Azure Storage Account. Must be globally unique
STORAGE_ACCOUNT_NAME=anyscale$RANDOM
# Name of the blob storage container we'll create in the storage account
STORAGE_CONTAINER_NAME=anyscale-container
# Namespace where the Anyscale Operator will be deployed
ANYSCALE_NAMESPACE=anyscale-operator
# Name of the cloud instance we'll use in the Anyscale Portal
# You should make this unique
ANYSCALE_CLOUD_INSTANCE_NAME=griff-anyscale-nap
```

Next we'll create the resource group and Azure Virtual Network, including the subnet that will be used for our Azure Storage Account Private Endpoint.

```bash
# Login to Azure and select the target deployment subscription
az login

# Create the resource group
az group create -g $RESOURCE_GROUP -l $LOCATION

# Create the Vnet along with the initial subet for AKS
az network vnet create \
-g $RESOURCE_GROUP \
-n $VNET_NAME \
--address-prefix 10.140.0.0/16 \
--subnet-name aks \
--subnet-prefix 10.140.0.0/24

# Get a subnet resource ID
AKS_VNET_SUBNET_ID=$(az network vnet subnet show -g $RESOURCE_GROUP --vnet-name $VNET_NAME -n aks -o tsv --query id)

# Create a subnet for the private endpoint
az network vnet subnet create \
-g $RESOURCE_GROUP \
--vnet-name $VNET_NAME \
-n storage-pe-subnet \
--address-prefix 10.140.1.0/24

# Get the storage subnet ID
STORAGE_SUBNET_ID=$(az network vnet subnet show -g $RESOURCE_GROUP --vnet-name $VNET_NAME -n storage-pe-subnet -o tsv --query id)

```

Now we'll create the storage account and it's private endpoint configuration.

```bash
# Create a storage account
az storage account create \
--name $STORAGE_ACCOUNT_NAME \
--resource-group $RESOURCE_GROUP \
--location $LOCATION \
--sku Standard_LRS

# Create a blob container
az storage container create \
--name anyscale-container \
--auth-mode login \
--account-name $STORAGE_ACCOUNT_NAME

# Disable public network access now that the container is created
az storage account update \
-n $STORAGE_ACCOUNT_NAME \
-g $RESOURCE_GROUP \
--public-network-access Disabled

# Create a private DNS zone for blob storage
az network private-dns zone create \
-g $RESOURCE_GROUP \
-n privatelink.blob.core.windows.net

# Link the private DNS zone to the VNet
az network private-dns link vnet create \
-g $RESOURCE_GROUP \
--zone-name privatelink.blob.core.windows.net \
-n storage-dns-link \
--virtual-network $VNET_NAME \
--registration-enabled false

# Create the private endpoint for blob storage
az network private-endpoint create \
-g $RESOURCE_GROUP \
-n ${STORAGE_ACCOUNT_NAME}-pe \
--vnet-name $VNET_NAME \
--subnet storage-pe-subnet \
--private-connection-resource-id $(az storage account show -n $STORAGE_ACCOUNT_NAME -g $RESOURCE_GROUP -o tsv --query id) \
--group-id blob \
--connection-name ${STORAGE_ACCOUNT_NAME}-pe-connection

# Create the private DNS zone group to automatically configure DNS
az network private-endpoint dns-zone-group create \
-g $RESOURCE_GROUP \
--endpoint-name ${STORAGE_ACCOUNT_NAME}-pe \
-n storage-dns-zone-group \
--private-dns-zone privatelink.blob.core.windows.net \
--zone-name blob
```

Before we create our AKS Cluster, we'll need to create a managed identity for the cluster and grant it rights on the VNet where we'll deploy AKS. This is, in part, because Node Auto-Provisioning will need the rights to attach a VM to the target subnet.

```bash
# Create the AKS Cluster Managed Identity
az identity create \
--name aks-cluster-mi \
--resource-group $RESOURCE_GROUP \
--location $LOCATION

# Get the managed identity principal ID
AKS_MI_PRINCIPAL_ID=$(az identity show --resource-group $RESOURCE_GROUP --name aks-cluster-mi --query principalId -o tsv)   

# Grant Network Contributor role to the managed identity on the VNet
az role assignment create \
--role "Network Contributor" \
--assignee $AKS_MI_PRINCIPAL_ID \
--scope $(az network vnet show -g $RESOURCE_GROUP -n $VNET_NAME --query id -o tsv)  

CLUSTER_MI_ID=$(az identity show --resource-group $RESOURCE_GROUP --name aks-cluster-mi --query id -o tsv)
```

```bash
# Cluster Creation Command
az aks create \
-g $RESOURCE_GROUP \
-n $CLUSTER_NAME \
--nodepool-name systempool \
--node-vm-size standard_d8s_v5 \
--node-count 1 \
--network-plugin azure \
--network-plugin-mode overlay \
--network-dataplane cilium \
--vnet-subnet-id $AKS_VNET_SUBNET_ID \
--pod-cidr 10.244.0.0/16 \
--service-cidr 10.245.0.0/24 \
--dns-service-ip 10.245.0.10 \
--enable-managed-identity \
--assign-identity $CLUSTER_MI_ID \
--enable-oidc-issuer \
--enable-workload-identity \
--node-provisioning-mode Auto \
--generate-ssh-keys

# Get the AKS Cluster credentials
az aks get-credentials -g $RESOURCE_GROUP -n $CLUSTER_NAME
```

Now we'll create the managed identity that the Anyscale Operator will use, and configure the federated identity credentials so that the Anyscale Operator can authenticate to the blob storage acccount using workload identity.

```bash
ANYSCALE_NAMESPACE=anyscale-operator 

# Get the OIDC Issuer URL
export AKS_OIDC_ISSUER="$(az aks show -n $CLUSTER_NAME -g $RESOURCE_GROUP --query "oidcIssuerProfile.issuerUrl" -otsv)"

# Create the managed identity
az identity create --name anyscale-mi --resource-group $RESOURCE_GROUP --location $LOCATION

# Get identity client ID
export USER_ASSIGNED_CLIENT_ID=$(az identity show --resource-group $RESOURCE_GROUP --name anyscale-mi --query 'clientId' -o tsv)

# Create the federated identity credential
az identity federated-credential create \
--name anyscale-federated-id \
--identity-name anyscale-mi \
--resource-group $RESOURCE_GROUP \
--issuer ${AKS_OIDC_ISSUER} \
--subject system:serviceaccount:${ANYSCALE_NAMESPACE}:anyscale-operator
```

Next we'll grant the managed identity rights to the storage account so that it can read and write blobs.

```bash
# Get the storage account resource ID
STORAGE_ACCOUNT_ID=$(az storage account show \
--name $STORAGE_ACCOUNT_NAME \
--resource-group $RESOURCE_GROUP \
--query id \
--output tsv)

# Get the managed identity principal ID
ANYSCALE_MI_PRINCIPAL_ID=$(az identity show \
--name anyscale-mi \
--resource-group $RESOURCE_GROUP \
--query principalId \
--output tsv)

# Grant Storage Blob Data Contributor role to the managed identity
# Note: If you're moving very fast you may get a "Cannot find user" error.
# Wait a few seconds and run the command again.
az role assignment create \
--role "Storage Blob Data Contributor" \
--assignee $ANYSCALE_MI_PRINCIPAL_ID \
--scope $STORAGE_ACCOUNT_ID
```

Anyscale requires an ingress controller to be installed in order to route traffic to the workloads deployed by Anyscale. Here we'll install the ingress-nginx controller via Helm.

```bash
# Generate the values file
cat << EOF > nginx-values.yaml
controller:
  service:
    type: LoadBalancer
    annotations:
      service.beta.kubernetes.io/azure-load-balancer-health-probe-request-path: "/healthz"
  allowSnippetAnnotations: true
  config:
    enable-underscores-in-headers: true
    annotations-risk-level: "Critical"
  autoscaling:
    enabled: true
EOF

# Add the ingress-nginx helm repository
helm repo add nginx https://kubernetes.github.io/ingress-nginx

# Run a helm repo update
helm repo update

# Install ingress-nginx
helm upgrade ingress-nginx nginx/ingress-nginx \
--version 4.12.1 \
--namespace ingress-nginx \
--values nginx-values.yaml \
--create-namespace \
--install

# Check the install
kubectl get all -n ingress-nginx
```

Next we'll register our Anyscale cloud instance using the anyscale CLI.

```bash
# Login to the anyscale CLI
anyscale login

# Anyscale API Key from the step above
export ANYSCALE_CLI_TOKEN=aph0_CkYwRAIgPvcAUkIqLcb_5ShQlgNxO69raLteRmHI2Vhp4r6WFAUCIElVIj9GUbX1eG9sP20DFXB4_jJ7TKqoaSJ4cQqwEp_2EmMSIKCarm-X_E7vO5q8Klg_EY4OPx4JVgaUo9fuM8VpwcSZGAEiHnVzcl9zcnc5Z3Nzcjh4Z2Ria2ltaDFsMXVoZnQ1bjoMCMOrkcoGEJjKwKECQgwIl4_zyAYQmMrAoQLyAQA

# Register the Anyscale cloud instance
anyscale cloud register \
--name $ANYSCALE_CLOUD_INSTANCE_NAME \
--region $LOCATION \
--provider azure \
--compute-stack k8s \
--cloud-storage-bucket-name "azure://${STORAGE_CONTAINER_NAME}" \
--cloud-storage-bucket-endpoint "https://${STORAGE_ACCOUNT_NAME}.blob.core.windows.net"
```

Finally, we can install the Anyscale Operator via Helm, using the cloudDeploymentId from the output of the `anyscale cloud register` command above.

```bash
helm repo add anyscale https://anyscale.github.io/helm-charts
helm repo update

# Get the 'cloudDeploymentId' from the Anyscale Cloud Register output
CLOUD_DEPLOYMENT_ID=cldrsrc_1s7rdrau4fzdnd1ldsibufc1bn

# Use the cloudDeploymentId from the output of the anyscale register command you ran above
helm upgrade anyscale-operator anyscale/anyscale-operator \
--set-string global.cloudDeploymentId=${CLOUD_DEPLOYMENT_ID} \
--set-string global.cloudProvider=azure \
--set-string global.auth.anyscaleCliToken=${ANYSCALE_CLI_TOKEN} \
--set-string workloads.serviceAccount.name=anyscale-operator \
--namespace $ANYSCALE_NAMESPACE \
--create-namespace \
--wait \
--values values.yaml \
-i
```


```bash
# To check the deployment status
kubectl get all -n $ANYSCALE_NAMESPACE

# Get the managed identity client id
MI_CLIENT_ID=$(az identity show -g $RESOURCE_GROUP -n anyscale-mi -o tsv --query clientId)

# Patch the service account to include the managed identity client id
kubectl patch sa anyscale-operator -n $ANYSCALE_NAMESPACE --type='json' -p="[{"op": "add", "path": "/metadata/annotations/azure.workload.identity~1client-id", "value": "$MI_CLIENT_ID"}]"

# Patch the service account to set the workload identity enabled flag
kubectl patch sa anyscale-operator -n $ANYSCALE_NAMESPACE --type='json' -p='[{"op": "add", "path": "/metadata/labels/azure.workload.identity~1use", "value": "true"}]'

kubectl delete pods -n anyscale-operator -l app=anyscale-operator

# Check the deployment status again and you should see the pods come up healthy
kubectl get all -n $ANYSCALE_NAMESPACE
```

Now, lets create our AKSNodeClass and NodePool resources to enable Node Auto-Provisioning for Anyscale workloads.


```bash
cat << EOF > anyscale-nodeclass.yaml
apiVersion: karpenter.azure.com/v1beta1
kind: AKSNodeClass
metadata:
  name: anyscale-nodeclass
  annotations:
    kubernetes.io/description: AKSNodeClass for Anyscale workloads
spec:
  imageFamily: Ubuntu
  osDiskSizeGB: 128
EOF

# Apply the AKSNodeClass
kubectl apply -f anyscale-nodeclass.yaml

cat << EOF > anyscalenodepool.yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  annotations:
    kubernetes.io/description: General purpose Anyscale NodePool for generic workloads
  generation: 1
  labels:
  name: anyscale-nodepool
spec:
  disruption:
    budgets:
    - nodes: 30%
    consolidateAfter: 0s
    consolidationPolicy: WhenEmptyOrUnderutilized
#   limits:
#     cpu: "73000"
#     memory: 2000Gi
  template:
    metadata:
      labels:
        kubernetes.azure.com/ebpf-dataplane: cilium
        karpenter.sh/capacity-type: on-demand
    spec:
      expireAfter: Never
      nodeClassRef:
        group: karpenter.azure.com
        kind: AKSNodeClass
        name: anyscale-nodeclass
      requirements:
      - key: kubernetes.io/arch
        operator: In
        values:
        - amd64
      - key: kubernetes.io/os
        operator: In
        values:
        - linux
      - key: karpenter.sh/capacity-type
        operator: In
        values:
        - on-demand
      - key: karpenter.azure.com/sku-family
        operator: In
        values:
        - NV
      - key: kubernetes.azure.com/ebpf-dataplane
        operator: In
        values:
        - cilium
      startupTaints:
      - effect: NoExecute
        key: node.cilium.io/agent-not-ready
        value: "true"
      - key: node.anyscale.com/capacity-type
        value: ON_DEMAND
        effect: NoSchedule
EOF


# Apply the NodePool
kubectl apply -f anyscalenodepool.yaml
```

Now you have an AKS cluster with Anyscale Operator installed and Node Auto-Provisioning enabled for Anyscale workloads. You can now deploy your Anyscale workloads and they will automatically scale based on demand.