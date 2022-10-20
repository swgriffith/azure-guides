
# Introduction

The following content and scripts walk through the setup of an [Azure Kubernetes Service](https://azure.microsoft.com/en-us/products/kubernetes-service/#overview) cluster, installation of [Elastic Search](https://www.elastic.co/what-is/elasticsearch) and the deployment and test of [Kasten K10](https://www.kasten.io/) for data protection and recovery.

This work is HEAVILY based on the work of my peer [Mohammad Nofal](https://www.linkedin.com/in/mnofal/). Thanks for this awesome work!

[https://github.com/mohmdnofal/aks-best-practices/tree/master/aks-kasten](https://github.com/mohmdnofal/aks-best-practices/tree/master/aks-kasten)

## Demo Network Infrastructure and Cluster Setup

In this walkthrough, we'll create a demo network and AKS cluster, with multiple node pools crossing Availability Zones in Azure. Lets create this source environment.

### Setup Env Vars

In the following, we'll set some variables for use throughout the setup. Feel free to adapt these values to your own needs, corp policies, etc.

```bash
LOCATION=eastus2 # Location 
AKS_NAME=aks-kasten
RG=$AKS_NAME-$LOCATION
AKS_VNET_NAME=$AKS_NAME-vnet # The VNET where AKS will reside
AKS_CLUSTER_NAME=$AKS_NAME-cluster # name of the cluster
AKS_VNET_CIDR=172.16.0.0/16 #VNET address space
AKS_NODES_SUBNET_NAME=$AKS_NAME-subnet # the AKS nodes subnet name
AKS_NODES_SUBNET_PREFIX=172.16.0.0/23 # the AKS nodes subnet address space
SERVICE_CIDR=10.0.0.0/16
DNS_IP=10.0.0.10
NETWORK_PLUGIN=azure # use azure CNI 
NETWORK_POLICY=calico # use calico network policy
SYSTEM_NODE_COUNT=3 # system node pool size (single pool with 3 nodes across AZs)
USER_NODE_COUNT=2 # 3 node pools with 2 nodes each 
NODES_SKU=Standard_D4as_v4 #node vm type 
K8S_VERSION=$(az aks get-versions  -l $LOCATION --query 'orchestrators[-1].orchestratorVersion' -o tsv) #get latest GA k8s version 
SYSTEM_POOL_NAME=systempool
STORAGE_POOL_ZONE1_NAME=espoolz1
STORAGE_POOL_ZONE2_NAME=espoolz2
STORAGE_POOL_ZONE3_NAME=espoolz3
IDENTITY_NAME=$AKS_NAME`date +"%d%m%y"` # cluster managed identity
```

### Create the resource group

```bash
az group create --name $RG --location $LOCATION
```

### Create the cluster identity

```bash
az identity create --name $IDENTITY_NAME --resource-group $RG
```

### Get the identity id and client id, we will use them later 

```bash
IDENTITY_ID=$(az identity show --name $IDENTITY_NAME --resource-group $RG --query id -o tsv)
IDENTITY_CLIENT_ID=$(az identity show --name $IDENTITY_NAME --resource-group $RG --query clientId -o tsv)
```

### Create the VNET and Subnet 

```bash
az network vnet create \
  --name $AKS_VNET_NAME \
  --resource-group $RG \
  --location $LOCATION \
  --address-prefix $AKS_VNET_CIDR \
  --subnet-name $AKS_NODES_SUBNET_NAME \
  --subnet-prefix $AKS_NODES_SUBNET_PREFIX
  ```

### Get the RG, VNET and Subnet IDs
```bash
RG_ID=$(az group show -n $RG  --query id -o tsv)
VNETID=$(az network vnet show -g $RG --name $AKS_VNET_NAME --query id -o tsv)
AKS_VNET_SUBNET_ID=$(az network vnet subnet show --name $AKS_NODES_SUBNET_NAME -g $RG --vnet-name $AKS_VNET_NAME --query "id" -o tsv)
```

### Assign the managed identity permissions on the RG and VNET

> *NOTE:* For the purposes of this demo we are setting the rights as highly unrestricted. You will want to set the rights below to meet your security needs.

```bash
az role assignment create --assignee $IDENTITY_CLIENT_ID --scope $RG_ID --role Contributor
az role assignment create --assignee $IDENTITY_CLIENT_ID --scope $VNETID --role Contributor

# Validate Role Assignment
az role assignment list --assignee $IDENTITY_CLIENT_ID --all -o table

----- Sample Output -----
Principal                             Role         Scope
------------------------------------  -----------  -------------------------------------------------------------------------------------------------------------------------------------------------------
c068a2aa-02b2-40b1-ba2c-XXXXXXXXXXXX  Contributor  /subscriptions/SUBID/resourceGroups/aks-storage-westus2
c068a2aa-02b2-40b1-ba2c-XXXXXXXXXXXX  Contributor  /subscriptions/SUBID/resourceGroups/aks-storage-westus2/providers/Microsoft.Network/virtualNetworks/aks-storage-vnet
```

### Create the cluster 
```bash
az aks create \
-g $RG \
-n $AKS_CLUSTER_NAME \
-l $LOCATION \
--node-count $SYSTEM_NODE_COUNT \
--node-vm-size $NODES_SKU \
--network-plugin $NETWORK_PLUGIN \
--kubernetes-version $K8S_VERSION \
--generate-ssh-keys \
--service-cidr $SERVICE_CIDR \
--dns-service-ip $DNS_IP \
--vnet-subnet-id $AKS_VNET_SUBNET_ID \
--enable-addons monitoring \
--enable-managed-identity \
--assign-identity $IDENTITY_ID \
--nodepool-name $SYSTEM_POOL_NAME \
--uptime-sla \
--zones 1 2 3 
```

### Get the credentials 

```bash
az aks get-credentials -n $AKS_CLUSTER_NAME -g $RG

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
--cluster-name $AKS_CLUSTER_NAME \
--mode User \
--name $STORAGE_POOL_ZONE1_NAME \
--node-vm-size $NODES_SKU \
--resource-group $RG \
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
--cluster-name $AKS_CLUSTER_NAME \
--mode User \
--name $STORAGE_POOL_ZONE2_NAME \
--node-vm-size $NODES_SKU \
--resource-group $RG \
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
--cluster-name $AKS_CLUSTER_NAME \
--mode User \
--name $STORAGE_POOL_ZONE3_NAME \
--node-vm-size $NODES_SKU \
--resource-group $RG \
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

### Deploy Elastic Search to the cluster  

```bash
# We start by creating our storage class 

cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: es-storageclass #storage class name
parameters:
  kind: Managed #we will use Azure managed disks
  storageaccounttype: Premium_LRS #use premium managed disk
  tags: costcenter=dev,app=elasticsearch  #add tags so all disks related to our application are tagged
provisioner: disk.csi.azure.com
reclaimPolicy: Retain #changed from default "Delete" to "Retain" so we can retain the disks even if the claim is deleted
volumeBindingMode: WaitForFirstConsumer #instrcuts the scheduler to wait for the pod to be scheduled before binding the disks
EOF

# Add the elastic search helm chart 
helm repo add bitnami https://charts.bitnami.com/bitnami

# Get the values file we'll need to update 
helm show values bitnami/elasticsearch > values_sample.yaml
```

We will create our own values file (there is a sample in this repo you can use) where we will 

1. Adjust the affinity and taints to match our node pools 
2. configure the storage class 
3. optionally make the elastic search service accessible using a load balancer 

```bash
# Create the namespace
kubectl create namespace elasticsearch

# Install elastic search using the values file 
helm install elasticsearch-v1 bitnami/elasticsearch -n elasticsearch --values values.yaml

# Validate the installation, it will take around 5 minutes for all the pods to move to a 'READY' state 
watch kubectl get pods -o wide -n elasticsearch


# Check the service so we can access elastic search, note the "External-IP" 
kubectl get svc -n elasticsearch elasticsearch-v1


# Lets store the value of the "elasticsearch-v1" service IP so we can use it later
esip=`kubectl get svc  elasticsearch-v1 -n elasticsearch -o=jsonpath='{.status.loadBalancer.ingress[0].ip}'`
```

Lets validate our deployment and insert some data 

```bash
# Get the version 
curl -XGET "http://$esip:9200"

# Sample Output
{
  "name" : "elasticsearch-v1-coordinating-1",
  "cluster_name" : "elastic",
  "cluster_uuid" : "kz5rkH_2T9W6u4sUPZE2oQ",
  "version" : {
    "number" : "8.2.0",
    "build_flavor" : "default",
    "build_type" : "tar",
    "build_hash" : "b174af62e8dd9f4ac4d25875e9381ffe2b9282c5",
    "build_date" : "2022-04-20T10:35:10.180408517Z",
    "build_snapshot" : false,
    "lucene_version" : "9.1.0",
    "minimum_wire_compatibility_version" : "7.17.0",
    "minimum_index_compatibility_version" : "7.0.0"
  },
  "tagline" : "You Know, for Search"
}


# Check the cluster health and check the shards 
curl "http://$esip:9200/_cluster/health?pretty"

# Sample Output
{
  "cluster_name" : "elastic",
  "status" : "green",
  "timed_out" : false,
  "number_of_nodes" : 18,
  "number_of_data_nodes" : 6,
  "active_primary_shards" : 5,
  "active_shards" : 10,
  "relocating_shards" : 0,
  "initializing_shards" : 0,
  "unassigned_shards" : 0,
  "delayed_unassigned_shards" : 0,
  "number_of_pending_tasks" : 0,
  "number_of_in_flight_fetch" : 0,
  "task_max_waiting_in_queue_millis" : 0,
  "active_shards_percent_as_number" : 100.0
}

# Insert some data and make sure you use 3 shards and a replica 
curl -X PUT "$esip:9200/customer/_doc/1?pretty" -H 'Content-Type: application/json' -d'{
    "name": "kubecon",
    "settings" : {"index" : {"number_of_shards" : 3, "number_of_replicas" : 1 }}}'

curl -X PUT "$esip:9200/customer/_doc/2?pretty" -H 'Content-Type: application/json' -d'{
    "name": "kasten",
    "settings" : {"index" : {"number_of_shards" : 3, "number_of_replicas" : 1 }}}'

# Validate the inserted doc 
curl "$esip:9200/customer/_search?q=*&pretty"

{
  "took" : 58,
  "timed_out" : false,
  "_shards" : {
    "total" : 1,
    "successful" : 1,
    "skipped" : 0,
    "failed" : 0
  },
  "hits" : {
    "total" : {
      "value" : 1,
      "relation" : "eq"
    },
    "max_score" : 1.0,
    "hits" : [
      {
        "_index" : "customer",
        "_id" : "1",
        "_score" : 1.0,
        "_source" : {
          "name" : "kubecon",
          "settings" : {
            "index" : {
              "number_of_shards" : 3,
              "number_of_replicas" : 1
            }
          }
        }
      }
    ]
  }
}

# Extra validations 
curl -X GET "$esip:9200/_cat/indices?v"

curl http://$esip:9200/_cat/shards/test\?pretty\=true
```

At this point you have a working Elastic Search cluster, running on a zone redundant AKS cluster. If you insert several records, and then watch the shards on those records while you delete pods, you should see that AKS will restart those pods and reattach storage, and also that Elastic Search has ensured your data is sharded across nodes, so that application requests will continue to be served as long as an active shard exists.

https://raw.githubusercontent.com/asyraffff/readme-with-video/main/README.md

## Install Kasten 

```bash
# Create an app registration for Kasten in azure active directory 
AZURE_SUBSCRIPTION_ID=$(az account list --query "[?isDefault][id]" --all -o tsv)

SP_NAME="kastensp"
AZURE_CLIENT_SECRET=`az ad sp create-for-rbac --name $SP_NAME --skip-assignment --query 'password' -o tsv`
AZURE_CLIENT_ID=`az ad sp list --display-name $SP_NAME --query '[0].appId' -o tsv`
AZURE_TENANT_ID=$(az account show -o tsv --query tenantId)

# Assign the SP Permission to the subcription
# This is done for simplicity only, you only need access to the resource groups where the cluster is and where the blob storage account will be 
az role assignment create --assignee $AZURE_CLIENT_ID  --role "Contributor"
az role assignment create --assignee $AZURE_CLIENT_ID  --role "User Access Administrator"
```

Now we need to create a snapshot configuration class for Kasten.

```bash
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

# Add the helm repo and install 
helm repo add kasten https://charts.kasten.io/
helm repo update 

# Run the pre checks 
curl https://docs.kasten.io/tools/k10_primer.sh | bash

# Create a namespace for Kasten 
kubectl create namespace kasten-io

# Install Kasten
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

# Validate 
kubectl get pods --namespace kasten-io

# Create the token secret for portal access
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: kasten-token
  namespace: kasten-io
  annotations:
    kubernetes.io/service-account.name: k10-k10
type: kubernetes.io/service-account-token
EOF

# Get the service account token so you can use it to access the dashboard 
kubectl get secret kasten-token -o yaml -n kasten-io -o jsonpath="{.data.token}"|base64 --decode

# Start a port-forward to access dashboard on localhost 
kubectl --namespace kasten-io port-forward service/gateway 8080:8000
```

In your browser, navigate to [http://localhost:8080/k10/#/](http://localhost:8080/k10/#/), paste the bearer token you retrieved in the step above and click 'Sign In'. You'll need to fill in a few fields to complete the setup.

### Create a storage account to ship the backed up files from Kasten to it 

```bash
# Define variables 
DATE=$(date +%Y%m%d)
PREFIX=kastendemo
BACKUP_RG=kasten-backup-${LOCATION}
STORAGE_ACCOUNT_NAME=${PREFIX}${DATE}backup 

# Create resource group 
az group create -n $BACKUP_RG -l $LOCATION

# reate storage account 
az storage account create \
    --name $STORAGE_ACCOUNT_NAME \
    --resource-group $BACKUP_RG \
    --sku Standard_GRS \
    --encryption-services blob \
    --https-only true \
    --kind BlobStorage \
    --access-tier Hot


STORAGE_ACCOUNT_KEY=$(az storage account keys list -g $BACKUP_RG -n $STORAGE_ACCOUNT_NAME --query "[0].value" -o tsv)

# Create blob container 
BLOB_CONTAINER=kasten
az storage container create -n $BLOB_CONTAINER --public-access off --account-name $STORAGE_ACCOUNT_NAME

#create secret for storage account 
AZURE_STORAGE_ENVIRONMENT=AzurePublicCloud
AZURE_STORAGE_SECRET=k10-azure-blob-backup

kubectl create secret generic $AZURE_STORAGE_SECRET \
      --namespace kasten-io \
      --from-literal=azure_storage_account_id=$STORAGE_ACCOUNT_NAME \
      --from-literal=azure_storage_key=$STORAGE_ACCOUNT_KEY \
      --from-literal=azure_storage_environment=$AZURE_STORAGE_ENVIRONMENT
```

Now create your backup profile and policy. You can adjust the backup policy to match your preferred backup time, but also for demo purposes I've provided a [BackupAction](https://docs.kasten.io/latest/api/actions.html#backupaction) example to trigger a manual backup.

```bash
cat <<EOF | kubectl apply -f -
kind: Profile
apiVersion: config.kio.kasten.io/v1alpha1
metadata:
  name: azure-backup-storage-location
  namespace: kasten-io
spec:
  locationSpec:
    type: ObjectStore
    objectStore:
      name: kasten
      objectStoreType: AZ
      region: $LOCATION
    credential:
      secretType: AzStorageAccount
      secret:
        apiVersion: v1
        kind: secret
        name: $AZURE_STORAGE_SECRET
        namespace: kasten-io
  type: Location
EOF

# Create the backup policy
cat <<EOF | kubectl apply -f -
apiVersion: config.kio.kasten.io/v1alpha1
kind: Policy
metadata:
  name: elastic-search-backup
  namespace: kasten-io
spec:
  comment: Elastic Search Backup Policy
  frequency: '@daily'
  subFrequency:
    minutes: [30]
    hours: [22,7]
    weekdays: [5]
    days: [15]
  retention:
    daily: 14
    weekly: 4
    monthly: 6
  actions:
  - action: backup
    backupParameters:
      profile:
        name: azure-backup-storage-location
        namespace: kasten-io
  selector:
    matchLabels:
      k10.kasten.io/appNamespace: elasticsearch
EOF

# To run a manual backup action
cat <<EOF | kubectl create -f -
apiVersion: actions.kio.kasten.io/v1alpha1
kind: BackupAction
metadata:
  generateName: backup-elasticsearch-
  namespace: elasticsearch
  labels:
    k10.kasten.io/appNamespace: "elasticsearch"
spec:
  subject:
    name: elasticsearch
    namespace: elasticsearch
EOF

```

### Enable Kasten DR

Navigate to the Kasten portal, click on 'Settings' and then 'K10 Disaster Recovery' and enable it. Make note of the cluster ID from the portal view. Alternatively, you can get the cluster ID with the following command. You can see the steps [here](https://docs.kasten.io/latest/operating/dr.html#enabling-k10-disaster-recovery)

```bash
kubectl get namespace default -ojsonpath="{.metadata.uid}{'\n'}"
```

## Conclusion - Part 1

You should now have a fully operational AKS cluster running Elastic Search, with some test data. You should also now have Kasten running in that cluster with a backup created. Now lets move on to recovery.

## Create the recovery cluster

Creating the second cluster is basically a repeat of the cluster creation steps above. In a real world scenario, you would just use a template to deploy and change the region target.

```bash
LOCATION=westus2 # Location 
AKS_NAME=aks-kasten
RG=$AKS_NAME-$LOCATION
AKS_VNET_NAME=$AKS_NAME-vnet # The VNET where AKS will reside
AKS_CLUSTER_NAME=$AKS_NAME-$LOCATION-cluster # name of the cluster
AKS_VNET_CIDR=172.16.0.0/16 #VNET address space
AKS_NODES_SUBNET_NAME=$AKS_NAME-subnet # the AKS nodes subnet name
AKS_NODES_SUBNET_PREFIX=172.16.0.0/23 # the AKS nodes subnet address space
SERVICE_CIDR=10.0.0.0/16
DNS_IP=10.0.0.10
NETWORK_PLUGIN=azure # use azure CNI 
NETWORK_POLICY=calico # use calico network policy
SYSTEM_NODE_COUNT=3 # system node pool size (single pool with 3 nodes across AZs)
USER_NODE_COUNT=2 # 3 node pools with 2 nodes each 
NODES_SKU=Standard_D4as_v4 #node vm type 
K8S_VERSION=$(az aks get-versions  -l $LOCATION --query 'orchestrators[-1].orchestratorVersion' -o tsv) #get latest GA k8s version 
SYSTEM_POOL_NAME=systempool
STORAGE_POOL_ZONE1_NAME=espoolz1
STORAGE_POOL_ZONE2_NAME=espoolz2
STORAGE_POOL_ZONE3_NAME=espoolz3
IDENTITY_NAME=$AKS_NAME`date +"%d%m%y"` # cluster managed identity
```

### Create the resource group

```bash
az group create --name $RG --location $LOCATION
```

### Create the cluster identity

```bash
az identity create --name $IDENTITY_NAME --resource-group $RG
```

### Get the identity id and client id, we will use them later 

```bash
IDENTITY_ID=$(az identity show --name $IDENTITY_NAME --resource-group $RG --query id -o tsv)
IDENTITY_CLIENT_ID=$(az identity show --name $IDENTITY_NAME --resource-group $RG --query clientId -o tsv)
```

### Create the VNET and Subnet 

```bash
az network vnet create \
  --name $AKS_VNET_NAME \
  --resource-group $RG \
  --location $LOCATION \
  --address-prefix $AKS_VNET_CIDR \
  --subnet-name $AKS_NODES_SUBNET_NAME \
  --subnet-prefix $AKS_NODES_SUBNET_PREFIX
```

### Get the RG, VNET and Subnet IDs

```bash
RG_ID=$(az group show -n $RG  --query id -o tsv)
VNETID=$(az network vnet show -g $RG --name $AKS_VNET_NAME --query id -o tsv)
AKS_VNET_SUBNET_ID=$(az network vnet subnet show --name $AKS_NODES_SUBNET_NAME -g $RG --vnet-name $AKS_VNET_NAME --query "id" -o tsv)
```

### Assign the managed identity permissions on the RG and VNET

> *NOTE:* For the purposes of this demo we are setting the rights as highly unrestricted. You will want to set the rights below to meet your security needs.

```bash
az role assignment create --assignee $IDENTITY_CLIENT_ID --scope $RG_ID --role Contributor
az role assignment create --assignee $IDENTITY_CLIENT_ID --scope $VNETID --role Contributor

# Validate Role Assignment
az role assignment list --assignee $IDENTITY_CLIENT_ID --all -o table

----- Sample Output -----
Principal                             Role         Scope
------------------------------------  -----------  -------------------------------------------------------------------------------------------------------------------------------------------------------
c068a2aa-02b2-40b1-ba2c-XXXXXXXXXXXX  Contributor  /subscriptions/SUBID/resourceGroups/aks-storage-westus2
c068a2aa-02b2-40b1-ba2c-XXXXXXXXXXXX  Contributor  /subscriptions/SUBID/resourceGroups/aks-storage-westus2/providers/Microsoft.Network/virtualNetworks/aks-storage-vnet
```

### Create the cluster 

```bash
az aks create \
-g $RG \
-n $AKS_CLUSTER_NAME \
-l $LOCATION \
--node-count $SYSTEM_NODE_COUNT \
--node-vm-size $NODES_SKU \
--network-plugin $NETWORK_PLUGIN \
--kubernetes-version $K8S_VERSION \
--generate-ssh-keys \
--service-cidr $SERVICE_CIDR \
--dns-service-ip $DNS_IP \
--vnet-subnet-id $AKS_VNET_SUBNET_ID \
--enable-addons monitoring \
--enable-managed-identity \
--assign-identity $IDENTITY_ID \
--nodepool-name $SYSTEM_POOL_NAME \
--uptime-sla \
--zones 1 2 3 
```

### get the credentials 

```bash
az aks get-credentials -n $AKS_CLUSTER_NAME -g $RG

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
--cluster-name $AKS_CLUSTER_NAME \
--mode User \
--name $STORAGE_POOL_ZONE1_NAME \
--node-vm-size $NODES_SKU \
--resource-group $RG \
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
--cluster-name $AKS_CLUSTER_NAME \
--mode User \
--name $STORAGE_POOL_ZONE2_NAME \
--node-vm-size $NODES_SKU \
--resource-group $RG \
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
--cluster-name $AKS_CLUSTER_NAME \
--mode User \
--name $STORAGE_POOL_ZONE3_NAME \
--node-vm-size $NODES_SKU \
--resource-group $RG \
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

### Setup Kasten for DR

```bash
# Create a passphrase for Kasten recovery
KASTEN_PASS=<YourPassphraseHere>

# Create the Kasten namespace
kubectl create ns kasten-io

# Create the secret for the Kasten DR Passphrase
kubectl create secret generic k10-dr-secret \
   --namespace kasten-io \
   --from-literal key=$KASTEN_PASS

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

# Create the secret for blob storage access
kubectl create secret generic $AZURE_STORAGE_SECRET \
      --namespace kasten-io \
      --from-literal=azure_storage_account_id=$STORAGE_ACCOUNT_NAME \
      --from-literal=azure_storage_key=$STORAGE_ACCOUNT_KEY \
      --from-literal=azure_storage_environment=$AZURE_STORAGE_ENVIRONMENT

# Deploy the location profile
cat <<EOF | kubectl apply -f -
kind: Profile
apiVersion: config.kio.kasten.io/v1alpha1
metadata:
  name: azure-backup-storage-location
  namespace: kasten-io
spec:
  locationSpec:
    type: ObjectStore
    objectStore:
      name: kasten
      objectStoreType: AZ
      region: $LOCATION
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

In the [Enable Kasten DR](#enable-kasten-dr) section above, you retrieved the source cluster ID. You'll need that here.

```bash
# Set the source cluster ID
SOURCE_CLUSTER_ID=<Insert the Source Cluster ID Here>

# Deploy the backup
helm install k10-restore kasten/k10restore --namespace=kasten-io \
    --set sourceClusterID=$SOURCE_CLUSTER_ID \
    --set profile.name=azure-backup-storage-location
```

### Go to the destination cluster portal to watch the Kasten DR restore

```bash
# Create the portal access token secret
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: kasten-token
  namespace: kasten-io
  annotations:
    kubernetes.io/service-account.name: k10-k10
type: kubernetes.io/service-account-token
EOF

# Get the service account token so you can use it to access the dashboard 
kubectl get secret kasten-token -o yaml -n kasten-io -o jsonpath="{.data.token}"|base64 --decode


# Start a port-forward to access dashboard on localhost 
kubectl --namespace kasten-io port-forward service/gateway 8080:8000
```

### Restore Elastic Search

First you need to determine what restore point to recover from. You can access this from the portal, or list all available restore points with the following:

```bash
kubectl get --raw /apis/apps.kio.kasten.io/v1alpha1/restorepointcontents|jq '.items[].status'
```

```bash
RESTORE_POINT_NAME=<InsertYourRestorePointName>

cat <<EOF | kubectl create -f -
apiVersion: actions.kio.kasten.io/v1alpha1
kind: RestoreAction
metadata:
  generateName: restore-elasticsearch
  namespace: elasticsearch
spec:
  subject:
    kind: RestorePoint
    name: $RESTORE_POINT_NAME
    namespace: elasticsearch
  targetNamespace: elasticsearch
EOF
```

### Now lets validate our data was restored

```bash
#lets store the value of the "elasticsearch-v1" service IP so we can use it later
esip_recovered=`kubectl get svc  elasticsearch-v1 -n elasticsearch -o=jsonpath='{.status.loadBalancer.ingress[0].ip}'`

# Look for the record we inserted in the other cluster
curl "$esip_recovered:9200/customer/_search?q=*&pretty"
```