# Create the secondary cluster

Creating the second cluster is basically a repeat of the cluster creation steps above. In a real world scenario, you would just use a template to deploy and change the region target.

```bash
SECONDARY_LOCATION=westus # Location 
SECONDARY_AKS_NAME=elastic-secondary
SECONDARY_RG=$SECONDARY_AKS_NAME-$SECONDARY_LOCATION
AKS_VNET_NAME=$SECONDARY_AKS_NAME-vnet # The VNET where AKS will reside
SECONDARY_AKS_CLUSTER_NAME=$SECONDARY_AKS_NAME-cluster # name of the cluster
AKS_VNET_CIDR=172.16.0.0/16 #VNET address space
AKS_NODES_SUBNET_NAME=$SECONDARY_AKS_NAME-subnet # the AKS nodes subnet name
AKS_NODES_SUBNET_PREFIX=172.16.0.0/23 # the AKS nodes subnet address space
SERVICE_CIDR=10.0.0.0/16
DNS_IP=10.0.0.10
NETWORK_PLUGIN=azure # use azure CNI 
NETWORK_POLICY=calico # use calico network policy
SYSTEM_NODE_COUNT=3 # system node pool size (single pool with 3 nodes across AZs)
USER_NODE_COUNT=2 # 3 node pools with 2 nodes each 
NODES_SKU=Standard_DS4_v2 #node vm type 
K8S_VERSION=1.27.1
SYSTEM_POOL_NAME=systempool
STORAGE_POOL_ZONE1_NAME=espoolz1
STORAGE_POOL_ZONE2_NAME=espoolz2
STORAGE_POOL_ZONE3_NAME=espoolz3
IDENTITY_NAME=$AKS_NAME`date +"%d%m%y"` # cluster managed identity
```

### Create the resource group

```bash
az group create --name $SECONDARY_RG --location $SECONDARY_LOCATION
```

### Create the VNET and Subnet 

```bash
az network vnet create \
  --name $AKS_VNET_NAME \
  --resource-group $SECONDARY_RG \
  --location $SECONDARY_LOCATION \
  --address-prefix $AKS_VNET_CIDR \
  --subnet-name $AKS_NODES_SUBNET_NAME \
  --subnet-prefix $AKS_NODES_SUBNET_PREFIX
  ```

### Get the RG, VNET and Subnet IDs
```bash
SECONDARY_RG_ID=$(az group show -n $SECONDARY_RG  --query id -o tsv)
SECONDARY_VNETID=$(az network vnet show -g $SECONDARY_RG --name $AKS_VNET_NAME --query id -o tsv)
SECONDARY_AKS_VNET_SUBNET_ID=$(az network vnet subnet show --name $AKS_NODES_SUBNET_NAME -g $SECONDARY_RG --vnet-name $AKS_VNET_NAME --query "id" -o tsv)
```

### Assign the managed identity permissions on the RG and VNET

> *NOTE:* For the purposes of this demo we are setting the rights as highly unrestricted. You will want to set the rights below to meet your security needs.

```bash
az role assignment create --assignee $IDENTITY_CLIENT_ID --scope $SECONDARY_RG_ID --role Contributor
az role assignment create --assignee $IDENTITY_CLIENT_ID --scope $SECONDARY_VNETID --role Contributor

# Validate Role Assignment
az role assignment list --assignee $IDENTITY_CLIENT_ID --all -o table

```

### Create the cluster 
```bash
az aks create \
-g $SECONDARY_RG \
-n $SECONDARY_AKS_CLUSTER_NAME \
-l $SECONDARY_LOCATION \
--node-count $SYSTEM_NODE_COUNT \
--node-vm-size $NODES_SKU \
--network-plugin $NETWORK_PLUGIN \
--kubernetes-version $K8S_VERSION \
--generate-ssh-keys \
--service-cidr $SERVICE_CIDR \
--dns-service-ip $DNS_IP \
--vnet-subnet-id $SECONDARY_AKS_VNET_SUBNET_ID \
--enable-addons monitoring \
--enable-managed-identity \
--assign-identity $IDENTITY_ID \
--nodepool-name $SYSTEM_POOL_NAME \
--uptime-sla \
--zones 1 2 3 
```

### Get the credentials 

```bash
az aks get-credentials -n $SECONDARY_AKS_CLUSTER_NAME -g $SECONDARY_RG

# validate nodes are running and spread across AZs
kubectl get nodes
NAME                                 STATUS   ROLES   AGE     VERSION
aks-systempool-26459571-vmss000000   Ready    agent   7d15h   v1.23.5
aks-systempool-26459571-vmss000001   Ready    agent   7d15h   v1.23.5
aks-systempool-26459571-vmss000002   Ready    agent   7d15h   v1.23.5

# check the system nodes spread over availaiblity zones 
kubectl describe nodes -l agentpool=systempool | grep -i topology.kubernetes.io/zone

                    topology.kubernetes.io/zone=westus2-1
                    topology.kubernetes.io/zone=westus2-2
                    topology.kubernetes.io/zone=westus2-3
```

### Add Additional Nodepools

```bash
# First Node Pool in Zone 1
az aks nodepool add \
--cluster-name $SECONDARY_AKS_CLUSTER_NAME \
--mode User \
--name $STORAGE_POOL_ZONE1_NAME \
--node-vm-size $NODES_SKU \
--resource-group $SECONDARY_RG \
--zones 1 \
--enable-cluster-autoscaler \
--max-count 4 \
--min-count 2 \
--node-count $USER_NODE_COUNT \
--node-taints app=ealsticsearch:NoSchedule \
--labels dept=dev purpose=storage \
--tags dept=dev costcenter=1000 \
--no-wait

# Second Node Pool in Zone 2
az aks nodepool add \
--cluster-name $SECONDARY_AKS_CLUSTER_NAME \
--mode User \
--name $STORAGE_POOL_ZONE2_NAME \
--node-vm-size $NODES_SKU \
--resource-group $SECONDARY_RG \
--zones 2 \
--enable-cluster-autoscaler \
--max-count 4 \
--min-count 2 \
--node-count $USER_NODE_COUNT \
--node-taints app=ealsticsearch:NoSchedule \
--labels dept=dev purpose=storage \
--tags dept=dev costcenter=1000 \
--no-wait


# Third Node Pool in Zone 3
az aks nodepool add \
--cluster-name $SECONDARY_AKS_CLUSTER_NAME \
--mode User \
--name $STORAGE_POOL_ZONE3_NAME \
--node-vm-size $NODES_SKU \
--resource-group $SECONDARY_RG \
--zones 3 \
--enable-cluster-autoscaler \
--max-count 4 \
--min-count 2 \
--node-count $USER_NODE_COUNT \
--node-taints app=ealsticsearch:NoSchedule \
--labels dept=dev purpose=storage \
--tags dept=dev costcenter=1000 \
--no-wait


# it will take couple of minutes to add the nodes, validate that nodes are added to the cluster and spread correctly 
kubectl get nodes -l dept=dev
# or
watch kubectl get nodes -l dept=dev

NAME                               STATUS   ROLES   AGE     VERSION
aks-espoolz1-21440163-vmss000000   Ready    agent   7d15h   v1.23.5
aks-espoolz1-21440163-vmss000001   Ready    agent   7d15h   v1.23.5
aks-espoolz2-14777997-vmss000000   Ready    agent   7d14h   v1.23.5
aks-espoolz2-14777997-vmss000001   Ready    agent   7d14h   v1.23.5
aks-espoolz3-54338334-vmss000000   Ready    agent   7d14h   v1.23.5
aks-espoolz3-54338334-vmss000001   Ready    agent   7d14h   v1.23.5


# Validate the zone distribution 
kubectl describe nodes -l dept=dev | grep -i topology.kubernetes.io/zone

                    topology.kubernetes.io/zone=westus2-1
                    topology.kubernetes.io/zone=westus2-1
                    topology.kubernetes.io/zone=westus2-2
                    topology.kubernetes.io/zone=westus2-2
                    topology.kubernetes.io/zone=westus2-3
                    topology.kubernetes.io/zone=westus2-3

# the Nodepool name will be added to the "agentpool" label on the nodes 
kubectl describe nodes -l dept=dev | grep -i agentpool
```

### Install Kasten

```bash
# Create the Kasten namespace
kubectl create ns kasten-io

# Create the volume snapshot class for Kasten
cat <<EOF | kubectl apply -f -
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
driver: disk.csi.azure.com
metadata:
  annotations:
    k10.kasten.io/is-snapshot-class: "true"
  name: csi-azure-disk-snapclass
deletionPolicy: Retain
EOF

# Install Kasten
# Note: We're reusing the identity created above for simplicity
helm install k10 kasten/k10 --namespace=kasten-io \
  --set secrets.azureTenantId=$AZURE_TENANT_ID \
  --set secrets.azureClientId=$AZURE_CLIENT_ID \
  --set secrets.azureClientSecret=$AZURE_CLIENT_SECRET \
  --set global.persistence.metering.size=1Gi \
  --set prometheus.server.persistentVolume.size=1Gi \
  --set global.persistence.catalog.size=1Gi \
  --set global.persistence.jobs.size=1Gi \
  --set global.persistence.logging.size=1Gi \
  --set global.persistence.grafana.size=1Gi \
  --set auth.tokenAuth.enabled=true \
  --set externalGateway.create=true \
  --set metering.mode=airgap 

# Watch the pods come online
watch kubectl get pods -n kasten-io
```

### Create the storage account and location profile

```bash
# Define variables 
DATE=$(date +%Y%m%d)
PREFIX=kastendemo
SECONDARY_STORAGE_ACCOUNT_NAME=${PREFIX}${SECONDARY_LOCATION} 

# reate storage account 
az storage account create \
    --name $SECONDARY_STORAGE_ACCOUNT_NAME \
    --resource-group $SECONDARY_RG \
    --sku Standard_GRS \
    --encryption-services blob \
    --https-only true \
    --kind BlobStorage \
    --access-tier Hot


SECONDARY_STORAGE_ACCOUNT_KEY=$(az storage account keys list -g $SECONDARY_RG -n $SECONDARY_STORAGE_ACCOUNT_NAME --query "[0].value" -o tsv)

# Create blob container 
BLOB_CONTAINER=kasten
az storage container create -n $BLOB_CONTAINER --public-access off --account-name $SECONDARY_STORAGE_ACCOUNT_NAME

#create secret for storage account 
AZURE_STORAGE_ENVIRONMENT=AzurePublicCloud
SECONDARY_AZURE_STORAGE_SECRET=k10-azure-blob-backup-secondary

kubectl create secret generic $SECONDARY_AZURE_STORAGE_SECRET \
      --namespace kasten-io \
      --from-literal=azure_storage_account_id=$SECONDARY_STORAGE_ACCOUNT_NAME \
      --from-literal=azure_storage_key=$SECONDARY_STORAGE_ACCOUNT_KEY \
      --from-literal=azure_storage_environment=$AZURE_STORAGE_ENVIRONMENT


# Deploy the location profile
cat <<EOF | kubectl apply -f -
kind: Profile
apiVersion: config.kio.kasten.io/v1alpha1
metadata:
  name: azure-backup-storage-secondary
  namespace: kasten-io
spec:
  locationSpec:
    type: ObjectStore
    objectStore:
      name: kasten
      objectStoreType: AZ
      region: $SECONDARY_LOCATION
    credential:
      secretType: AzStorageAccount
      secret:
        apiVersion: v1
        kind: secret
        name: $SECONDARY_AZURE_STORAGE_SECRET
        namespace: kasten-io
  type: Location
EOF
```

Now we need to add a location profile for the primary region.

```bash
#create secret for storage account 
AZURE_STORAGE_ENVIRONMENT=AzurePublicCloud
AZURE_STORAGE_SECRET=k10-azure-blob-backup

kubectl create secret generic $AZURE_STORAGE_SECRET \
      --namespace kasten-io \
      --from-literal=azure_storage_account_id=$PRIMARY_STORAGE_ACCOUNT_NAME \
      --from-literal=azure_storage_key=$PRIMARY_STORAGE_ACCOUNT_KEY \
      --from-literal=azure_storage_environment=$AZURE_STORAGE_ENVIRONMENT

cat <<EOF | kubectl apply -f -
kind: Profile
apiVersion: config.kio.kasten.io/v1alpha1
metadata:
  name: azure-backup-storage-primary
  namespace: kasten-io
spec:
  locationSpec:
    type: ObjectStore
    objectStore:
      name: kasten
      objectStoreType: AZ
      region: $PRIMARY_LOCATION
    credential:
      secretType: AzStorageAccount
      secret:
        apiVersion: v1
        kind: secret
        name: $AZURE_STORAGE_SECRET
        namespace: kasten-io
  type: Location
EOF

```

Now lets get the token and portal URL and check out our secondary instance.

```bash
sa_secret=$(kubectl get serviceaccount k10-k10 -o jsonpath="{.secrets[0].name}" --namespace kasten-io)

echo $(kubectl get secret $sa_secret --namespace kasten-io -ojsonpath="{.data.token}{'\n'}" | base64 --decode)

# Take the token and navigate to the URL output from the command below to login to the Kasten dashboard
kastenip=$(kubectl get svc gateway-ext -n kasten-io -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "http://${kastenip}/k10/#/"
```

It would be nice to see these cluster in Kasten multi-cluster view, so lets set that up. You'll need the k10multicluster cli which you can find here [https://docs.kasten.io/latest/multicluster/k10multicluster.html](https://docs.kasten.io/latest/multicluster/k10multicluster.html)

```bash
# Check the context names for your primary and secondary clusters
kubectl config get-contexts

# Set up the primary
k10multicluster setup-primary \
    --context=elastic-primary-cluster   \
    --name=primary

# Set up the secondary
k10multicluster bootstrap \
    --primary-context=elastic-primary-cluster  \
    --primary-name=primary \
    --secondary-context=elastic-secondary-cluster \
    --secondary-name=secondary \
    --secondary-cluster-ingress="http://${kastenip}/k10"
```

If you navigate to your primary dashboard you should see the multi-cluster user experience.

### Restore Elastic Search from the Primary export

First we need to get the recieve string from the export in our primary cluster.

> *Note:*
> Due to an issue I havent yet worked out with restoring to tainted nodes, I had to run the following. I'd love a PR from someone that knows the solution to this issue.

```bash
# Remove the nodepool taints
az aks nodepool update -g $SECONDARY_RG --cluster-name $SECONDARY_AKS_CLUSTER_NAME -n espoolz1 --node-taints ""
az aks nodepool update -g $SECONDARY_RG --cluster-name $SECONDARY_AKS_CLUSTER_NAME -n espoolz2 --node-taints ""
az aks nodepool update -g $SECONDARY_RG --cluster-name $SECONDARY_AKS_CLUSTER_NAME -n espoolz3 --node-taints ""
```

```bash
# Get the contexts
kubectl config get-contexts

# Use the primary context
kubectl config use-context elastic-primary-cluster

# Get the recieve string
EXPORT_RECIEVE_STRING=$(kubectl get policy es-backup-export -n kasten-io -o jsonpath='{.spec.actions[?(@.action=="export")].exportParameters.receiveString}')

# Switch context back to secondary
kubectl config use-context elastic-secondary-cluster
```

Now create the import policy.

```bash
cat <<EOF | kubectl apply -f -
apiVersion: config.kio.kasten.io/v1alpha1
kind: Policy
metadata:
  name: es-import-policy
  namespace: kasten-io
spec:
  comment: Elastic Search import policy
  frequency: '@hourly'
  actions:
  - action: import
    importParameters:
      profile:
        namespace: kasten-io
        name: azure-backup-storage-primary
      receiveString: ${EXPORT_RECIEVE_STRING}
  - action: restore
    restoreParameters:
      restoreClusterResources: true
EOF

# Execute the import manually
cat <<EOF | kubectl create -f -
apiVersion: actions.kio.kasten.io/v1alpha1
kind: RunAction
metadata:
  generateName: run-es-backup-import-
spec:
  subject:
    kind: Policy
    name: es-import-policy
    namespace: kasten-io
EOF
```

At this point the Elastic Search resources and data should be restored from the primary cluster to the secondary cluster. Let's test to verify.

```bash
# Lets store the value of the "elasticsearch-v1" service IP so we can use it later
secondary_esip=`kubectl get svc  elasticsearch-v1 -n elasticsearch -o=jsonpath='{.status.loadBalancer.ingress[0].ip}'`

# Get the version 
curl -XGET "http://$secondary_esip:9200"

# Validate the inserted doc 
curl "$secondary_esip:9200/customer/_search?q=*&pretty"

# Check the index shards
curl http://$secondary_esip:9200/_cat/shards/customer\?pretty\=true

```

You should now have a fully configured multi-region restorable Elastic Search environment. Congrats! Please feel free to reach out if you have any issues!