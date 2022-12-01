# External DNS with Azure Private Zones

The following walk-through shows how to use the [External DNS](https://github.com/kubernetes-sigs/external-dns) project to monitor for services with DNS annotation to automatically create DNS records in an Azure Private Zone.

### Set Env Variables

Update the following with your own prefered values.

```bash
RG=EphExternalDNSDemo
LOC=eastus
AZURE_DNS_ZONE="griffdemo123.com" # DNS zone name like example.com or sub.example.com
CLUSTER_NAME=externaldns
TENANT_ID=$(az account show --query tenantId -o tsv)
SUB_ID=$(az account show --query id -o tsv)
```

### Create the Resource Group and Vnet

Now to create the resource group and Vnet which we will use for both the private zone and the AKS cluster.

```bash
# Create the Resource Group
az group create -n $RG -l $LOC

# Create the Vnet
az network vnet create \
--name testvnet \
--resource-group $RG \
--address-prefix 10.2.0.0/16 \
--subnet-name aks \
--subnet-prefixes 10.2.0.0/24

# Get the subnet id for later use
SUBNET_ID=$(az network vnet subnet show -g $RG --vnet-name testvnet -n aks -o tsv --query id)
```

### Create the Private DNS Zone

Now to create the private zone and link it to the vnet.

```bash
# Create the DNS Zone
az network private-dns zone create \
--resource-group $RG \
--name $AZURE_DNS_ZONE

# Link the private zone to the vnet
az network private-dns link vnet create \
-g $RG \
-n zonelink \
-z $AZURE_DNS_ZONE \
-v testvnet \
--registration-enabled false
```

### Create the AKS Cluster

We'll create the AKS cluster in the above created subnet, and enable managed identity. We'll use the cluster 'kubelet' managed identity to access the private zone.

```bash
# Create the AKS Cluster
az aks create \
-g $RG \
-n $CLUSTER_NAME \
--vnet-subnet-id $SUBNET_ID \
--enable-managed-identity

# Get the cluster credentials
az aks get-credentials \
-g $RG \
-n $CLUSTER_NAME 
```

### Setup Access for the Kubelet Identity

As mentioned above, we'll use the cluster's managed kubelet identity to access the private zone. For this the kubelet identity will need read access against the resource group containing private DNS zone, as well as contributor rights on the private zone itself.

```bash
# Get the kubelet managed identity
KUBELET_IDENTITY=$(az aks show -g $RG -n $CLUSTER_NAME \
--query "identityProfile.kubeletidentity.objectId" \
--output tsv)

# Get the resource group ID
RG_ID=$(az group show -n $RG -o tsv --query id)

# Get the DNS Zone ID
DNS_ID=$(az network private-dns zone show --name $AZURE_DNS_ZONE \
 --resource-group $RG --query "id" --output tsv)

# Give the kubelet identity DNS Contributor rights
az role assignment create \
--assignee $KUBELET_IDENTITY \
--role "Private DNS Zone Contributor" \
--scope "$DNS_ID"

az role assignment create \
--role "Reader" \
--assignee $KUBELET_IDENTITY \
--scope $RG_ID
```

### Install External DNS

We'll install External DNS using it's helm chart, setting the values to ensure we're using the Azure Private DNS provider and pass in the managed identity details.

```bash
# Add the helm repo
helm repo add bitnami https://charts.bitnami.com/bitnami

# Update the helm repo in case you already have it
helm repo update bitnami

# Install external dns
helm install external-dns bitnami/external-dns \
--set "provider=azure-private-dns" \
--set "azure.resourceGroup=$RG" \
--set "azure.tenantId=$TENANT_ID" \
--set "azure.subscriptionId=$SUB_ID" \
--set "azure.useManagedIdentityExtension=true" \
--set "logLevel=debug" \
--set "domainFilters={$AZURE_DNS_ZONE}" \
--set "txtOwnerId=external-dns"
```

### Test External DNS

Finally, lets make sure everything is working. We'll create a deployment and a service with both a private load balancer annotation and the annotation used by External DNS to trigger record creation.

```bash
# Test ExternalDNS
cat << EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx
spec:
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
      - image: nginx
        name: nginx
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: nginx-svc
  annotations:
    external-dns.alpha.kubernetes.io/hostname: hello.griffdemo123.com
    service.beta.kubernetes.io/azure-load-balancer-internal: "true"
spec:
  ports:
  - port: 80
    protocol: TCP
    targetPort: 80
  selector:
    app: nginx
  type: LoadBalancer
EOF
```

You can check the logs for external DNS as follows:

```bash
# To dump the current pod logs
kubectl logs -l app.kubernetes.io/instance=external-dns

# To follow the pod logs
kubectl logs -f -l app.kubernetes.io/instance=external-dns
```

Show the records created.

```bash
az network private-dns record-set a list -g $RG -z $AZURE_DNS_ZONE -o table

# SAMPLE OUTPUT
Name    ResourceGroup       Ttl    Type    AutoRegistered    Metadata
------  ------------------  -----  ------  ----------------  ----------
hello   ephexternaldnsdemo  300    A       False
```