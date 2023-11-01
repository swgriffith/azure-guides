# Primary Cluster Setup

This walk through will create the primary cluster, deploy Elastic Search, run some quick tests, and then will deploy Kasten K10 and setup and execute a backup policy for our Elastic Search workload.

### Setup Env Vars

In the following, we'll set some variables for use throughout the setup. Feel free to adapt these values to your own needs, corp policies, etc.

> *Note:*
> In the following I explicitly set the Kubernetes version to one supported by Kasten. You should review version support and set accordingly. You can review the supported versions [here](https://docs.kasten.io/latest/operating/support.html)

```bash
PRIMARY_LOCATION=eastus # Location 
PRIMARY_AKS_NAME=elastic-primary
PRIMARY_RG=$PRIMARY_AKS_NAME-$PRIMARY_LOCATION
AKS_VNET_NAME=$PRIMARY_AKS_NAME-vnet # The VNET where AKS will reside
PRIMARY_AKS_CLUSTER_NAME=$PRIMARY_AKS_NAME-cluster # name of the cluster
AKS_VNET_CIDR=172.16.0.0/16 #VNET address space
AKS_NODES_SUBNET_NAME=$PRIMARY_AKS_NAME-subnet # the AKS nodes subnet name
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
az group create --name $PRIMARY_RG --location $PRIMARY_LOCATION
```

### Create the cluster identity

We're going to reuse the cluster identity created below for simplicity, but in a real world scneario you may prefer to maintain separate identities.

```bash
az identity create --name $IDENTITY_NAME --resource-group $PRIMARY_RG
```

### Get the identity id and client id, we will use them later 

```bash
IDENTITY_ID=$(az identity show --name $IDENTITY_NAME --resource-group $PRIMARY_RG --query id -o tsv)
IDENTITY_CLIENT_ID=$(az identity show --name $IDENTITY_NAME --resource-group $PRIMARY_RG --query clientId -o tsv)
```

### Create the VNET and Subnet 

```bash
az network vnet create \
  --name $AKS_VNET_NAME \
  --resource-group $PRIMARY_RG \
  --location $PRIMARY_LOCATION \
  --address-prefix $AKS_VNET_CIDR \
  --subnet-name $AKS_NODES_SUBNET_NAME \
  --subnet-prefix $AKS_NODES_SUBNET_PREFIX
  ```

### Get the RG, VNET and Subnet IDs
```bash
PRIMARY_RG_ID=$(az group show -n $PRIMARY_RG  --query id -o tsv)
PRIMARY_VNETID=$(az network vnet show -g $PRIMARY_RG --name $AKS_VNET_NAME --query id -o tsv)
PRIMARY_AKS_VNET_SUBNET_ID=$(az network vnet subnet show --name $AKS_NODES_SUBNET_NAME -g $PRIMARY_RG --vnet-name $AKS_VNET_NAME --query "id" -o tsv)
```

### Assign the managed identity permissions on the RG and VNET

> *NOTE:* For the purposes of this demo we are setting the rights as highly unrestricted. You will want to set the rights below to meet your security needs.

```bash
az role assignment create --assignee $IDENTITY_CLIENT_ID --scope $PRIMARY_RG_ID --role Contributor
az role assignment create --assignee $IDENTITY_CLIENT_ID --scope $PRIMARY_VNETID --role Contributor

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
-g $PRIMARY_RG \
-n $PRIMARY_AKS_CLUSTER_NAME \
-l $PRIMARY_LOCATION \
--node-count $SYSTEM_NODE_COUNT \
--node-vm-size $NODES_SKU \
--network-plugin $NETWORK_PLUGIN \
--kubernetes-version $K8S_VERSION \
--generate-ssh-keys \
--service-cidr $SERVICE_CIDR \
--dns-service-ip $DNS_IP \
--vnet-subnet-id $PRIMARY_AKS_VNET_SUBNET_ID \
--enable-addons monitoring \
--enable-managed-identity \
--assign-identity $IDENTITY_ID \
--nodepool-name $SYSTEM_POOL_NAME \
--uptime-sla \
--zones 1 2 3 
```

### Get the credentials 

```bash
az aks get-credentials -n $PRIMARY_AKS_CLUSTER_NAME -g $PRIMARY_RG

# validate nodes are running and spread across AZs
kubectl get nodes
NAME                                 STATUS   ROLES   AGE     VERSION
aks-systempool-26459571-vmss000000   Ready    agent   7d15h   v1.23.5
aks-systempool-26459571-vmss000001   Ready    agent   7d15h   v1.23.5
aks-systempool-26459571-vmss000002   Ready    agent   7d15h   v1.23.5

# check the system nodes spread over availaiblity zones 
kubectl describe nodes -l agentpool=systempool | grep -i topology.kubernetes.io/zone

                    topology.kubernetes.io/zone=eastus-1
                    topology.kubernetes.io/zone=eastus-2
                    topology.kubernetes.io/zone=eastus-3
```

### Add Additional Nodepools

```bash
# First Node Pool in Zone 1
az aks nodepool add \
--cluster-name $PRIMARY_AKS_CLUSTER_NAME \
--mode User \
--name $STORAGE_POOL_ZONE1_NAME \
--node-vm-size $NODES_SKU \
--resource-group $PRIMARY_RG \
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
--cluster-name $PRIMARY_AKS_CLUSTER_NAME \
--mode User \
--name $STORAGE_POOL_ZONE2_NAME \
--node-vm-size $NODES_SKU \
--resource-group $PRIMARY_RG \
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
--cluster-name $PRIMARY_AKS_CLUSTER_NAME \
--mode User \
--name $STORAGE_POOL_ZONE3_NAME \
--node-vm-size $NODES_SKU \
--resource-group $PRIMARY_RG \
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
# This may take some timeo n the initial request
curl -XGET "http://$esip:9200"

# Sample Output
{
  "name" : "elasticsearch-v1-coordinating-2",
  "cluster_name" : "elastic",
  "cluster_uuid" : "tlBV4CkaQHWa2usLTzlTgw",
  "version" : {
    "number" : "8.9.0",
    "build_flavor" : "default",
    "build_type" : "tar",
    "build_hash" : "8aa461beb06aa0417a231c345a1b8c38fb498a0d",
    "build_date" : "2023-07-19T14:43:58.555259655Z",
    "build_snapshot" : false,
    "lucene_version" : "9.7.0",
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
  "active_primary_shards" : 0,
  "active_shards" : 0,
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
  "took" : 139,
  "timed_out" : false,
  "_shards" : {
    "total" : 1,
    "successful" : 1,
    "skipped" : 0,
    "failed" : 0
  },
  "hits" : {
    "total" : {
      "value" : 2,
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
      },
      {
        "_index" : "customer",
        "_id" : "2",
        "_score" : 1.0,
        "_source" : {
          "name" : "kasten",
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

# Check the index shards
curl http://$esip:9200/_cat/shards/customer\?pretty\=true
```

At this point you have a working Elastic Search cluster, running on a zone redundant AKS cluster. If you insert several records, and then watch the shards on those records while you delete pods, you should see that AKS will restart those pods and reattach storage, and also that Elastic Search has ensured your data is sharded across nodes, so that application requests will continue to be served as long as an active shard exists.

https://user-images.githubusercontent.com/16705496/196979113-b463e775-d016-49b9-baf7-12107e0e9d41.mp4

Now lets work on application data recovery! We need to install Kasten!!!

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

# Get a temporary bearer token to be used to authenticate to the dashboard
# Copy the output value for the next step
kubectl --namespace kasten-io create token k10-k10 --duration=24h

# Take the token and navigate to the URL output from the command below to login to the Kasten dashboard
echo "http://$(kubectl get svc gateway-ext -n kasten-io -o jsonpath='{.status.loadBalancer.ingress[0].ip}')/k10/#/"

# Answer the questions in the dashboard login
```

### Create a storage account to ship the backed up files from Kasten to it 

```bash
# Define variables 
DATE=$(date +%Y%m%d)
PREFIX=kastendemo
PRIMARY_STORAGE_ACCOUNT_NAME=${PREFIX}${DATE}backup 

# reate storage account 
az storage account create \
    --name $PRIMARY_STORAGE_ACCOUNT_NAME \
    --resource-group $PRIMARY_RG \
    --sku Standard_GRS \
    --encryption-services blob \
    --https-only true \
    --kind BlobStorage \
    --access-tier Hot


PRIMARY_STORAGE_ACCOUNT_KEY=$(az storage account keys list -g $PRIMARY_RG -n $PRIMARY_STORAGE_ACCOUNT_NAME --query "[0].value" -o tsv)

# Create blob container 
BLOB_CONTAINER=kasten
az storage container create -n $BLOB_CONTAINER --public-access off --account-name $PRIMARY_STORAGE_ACCOUNT_NAME

#create secret for storage account 
AZURE_STORAGE_ENVIRONMENT=AzurePublicCloud
AZURE_STORAGE_SECRET=k10-azure-blob-backup

kubectl create secret generic $AZURE_STORAGE_SECRET \
      --namespace kasten-io \
      --from-literal=azure_storage_account_id=$PRIMARY_STORAGE_ACCOUNT_NAME \
      --from-literal=azure_storage_key=$PRIMARY_STORAGE_ACCOUNT_KEY \
      --from-literal=azure_storage_environment=$AZURE_STORAGE_ENVIRONMENT
```

Now create your backup profile and policy. You can adjust the backup policy to match your preferred backup time, but also for demo purposes I've provided a [Run Action](https://docs.kasten.io/latest/api/actions.html#runaction) example to trigger a manual backup.

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


# Create the backup policy
cat <<EOF | kubectl apply -f -
kind: Policy
apiVersion: config.kio.kasten.io/v1alpha1
metadata:
  name: es-backup-export
  namespace: kasten-io
spec:
  frequency: "@hourly"
  retention:
    hourly: 24
    daily: 7
    weekly: 4
    monthly: 12
    yearly: 7
  selector:
    matchExpressions:
      - key: k10.kasten.io/appNamespace
        operator: In
        values:
          - elasticsearch
          - kasten-io-cluster
  actions:
    - action: backup
      backupParameters:
        profile:
          name: azure-backup-storage-location
          namespace: kasten-io
    - action: export
      exportParameters:
        frequency: "@hourly"
        profile:
          name: azure-backup-storage-location
          namespace: kasten-io
        exportData:
          enabled: true
EOF

# We could wait for our hourly backup to run, but lets just fire it off manually
cat <<EOF | kubectl create -f -
apiVersion: actions.kio.kasten.io/v1alpha1
kind: RunAction
metadata:
  generateName: run-es-backup-export-
spec:
  subject:
    kind: Policy
    name: es-backup-export
    namespace: kasten-io
EOF

```

Woohoo! Now you should have an operational instance of Kasten on your cluster with a backup/export policy for your Elastic Search instance and one backup/export run. If you were to wreck your data, you should now be able to restore from a restore point. Note, the following video has has been shortened to minimize it's size, but as you can see the restore took about 2 minutes. Restore time will vary based on data volume and restore configuration.

In the following video I delete the customer index and then run a Kasten restore to bring the index back.

https://user-images.githubusercontent.com/16705496/197001830-151d30db-44af-404b-b919-20046509e5ac.mp4

