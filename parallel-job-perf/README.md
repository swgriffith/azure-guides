# Parallel Job Perf Example


```bash
RG=EphParallelJob
LOC=eastus
ACR_NAME=paralleltestgriff
CLUSTER_NAME=paralleltest
SYS_POOL_NAME=syspool
USER_POOL_NAME=userpool

az group create -n $RG -l $LOC

az acr create -g $RG -n $ACR_NAME --sku premium

az aks create -g $RG -n $CLUSTER_NAME \
--nodepool-name $SYS_POOL_NAME \
-c 1 \
--nodepool-taints CriticalAddonsOnly=true:NoSchedule

az aks update -g $RG -n $CLUSTER_NAME --attach-acr $ACR_NAME

az acr import --name $ACR_NAME --source docker.io/devopscube/kubernetes-job-demo:latest --image devopscube/kubernetes-job-demo:latest
az acr import --name $ACR_NAME --source docker.io/library/ubuntu --image ubuntu

az aks nodepool add -g $RG \
--cluster-name $CLUSTER_NAME \
-n $USER_POOL_NAME \
-c 1 

az aks nodepool add -g $RG \
--cluster-name $CLUSTER_NAME \
-n ds4v2pool \
--node-vm-size Standard_DS4_v2 \
-c 1 

az aks nodepool add -g $RG \
--cluster-name $CLUSTER_NAME \
-n ds12v2pool \
--node-vm-size Standard_DS12_v2 \
-c 1 

az aks get-credentials -g $RG -n $CLUSTER_NAME
```

### DS2v2 Single Node Test

```bash
# Start 5 parallel jobs
kubectl create -f 5_job.yaml
# Wait to complete
watch kubectl get jobs

# Start 20 parallel jobs
kubectl create -f 20_job.yaml
# Wait to complete
watch kubectl get jobs

# Start 100 parallel jobs
kubectl create -f 100_job.yaml
# Wait to complete
watch kubectl get jobs


```