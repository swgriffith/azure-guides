# KEDA CPU Scaler

## Setup

```bash
RG=EphKedaCPUScaling
CLUSTER_NAME=lab
LOC=eastus2

az group create -n $RG -l $LOC

az aks create \
-g $RG \
-n $CLUSTER_NAME \
--enable-keda

az aks get-credentials -g $RG -n $CLUSTER_NAME

kubectl apply -f cpu-stressor.yaml
kubectl apply -f scaledobject.yaml

watch kubectl get rs,pods

kubectl delete -f cpu-stressor.yaml
kubectl delete -f scaledobject.yaml
```