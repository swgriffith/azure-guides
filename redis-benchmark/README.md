# Azure Redis Benchmark Test

## Create the environment

```bash
RG=EphRedisBenchmark
LOC=eastus
CLUSTER_NAME=wilab
UNIQUE_ID=$CLUSTER_NAME$RANDOM
REDIS_NAME=$UNIQUE_ID

# Create the resource group
az group create -g $RG -l $LOC

# Create the cluster with the OIDC Issuer and Workload Identity enabled
az aks create -g $RG -n $CLUSTER_NAME \
--node-count 1 \
--enable-oidc-issuer \
--enable-workload-identity \
--zone 1 \
--nodepool-name zone1 \
--generate-ssh-keys

# Add the nodepool
az aks nodepool add \
--resource-group $RG \
--cluster-name $CLUSTER_NAME \
--node-vm-size Standard_D2_v4 \
--name zone2 \
--zone 2 \
--nodepool-name zone2 \
--mode User

# Get the cluster credentials
az aks get-credentials -g $RG -n $CLUSTER_NAME

# Create the Redis Instance
az redis create \
--resource-group $RG \
--name $REDIS_NAME \
--location $LOC \
--sku Premium \
--vm-size P1 \
--zones 1

# Deploy the zone 1 test client
kubectl apply -f redis-benchmark-zone1.yaml

# Deploy the zone 2 test client
kubectl apply -f redis-benchmark-zone2.yaml

REDIS_HOST=$(az redis show -g $RG -n $REDIS_NAME -o tsv --query hostName)
REDIS_ACCESS_KEY=$(az redis list-keys -g $RG -n $REDIS_NAME -o tsv --query primaryKey)

kubectl exec -it redis-zone1 -- redis-benchmark -h $REDIS_HOST -a $REDIS_ACCESS_KEY -t SET -n 10 -d 1024

kubectl exec -it redis-zone2 -- redis-benchmark -h $REDIS_HOST -a $REDIS_ACCESS_KEY -t SET -n 10 -d 1024

```