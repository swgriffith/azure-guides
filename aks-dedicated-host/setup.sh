#!/bin/bash

# Set Environment Variables
RG=EphTestADH
LOC=eastus2
CLUSTER_NAME=adhtest

# Create resource group and get its resource ID
az group create -n $RG -l $LOC
RG_ID=$(az group show -n $RG -o tsv --query id)

# Create the dedicated host group and get its id
az vm host group create \
--name akshostgroup \
-g $RG \
-z 1 \
--platform-fault-domain-count 1 \
--automatic-placement true

HOST_GROUP_ID=$(az vm host group show -n akshostgroup -g $RG -o tsv --query id)

# Create the host on the host group
az vm host create \
--host-group akshostgroup \
--name nodepool1 \
--sku DSv3-Type1 \
--platform-fault-domain 0 \
-g $RG

# Create an identity for the cluster
az identity create -g $RG -n aksclusteridentity
CLUSTER_IDENT_ID=$(az identity show -g $RG -n aksclusteridentity -o tsv --query id)
CLUSTER_CLIENT_ID=$(az identity show -g $RG -n aksclusteridentity -o tsv --query clientId)

# Wait a few seconds for the identity to be ready for role assignment
sleep 30

# Give the cluster identity contributor on the host group resource group
az role assignment create --assignee $CLUSTER_CLIENT_ID --role "Contributor" --scope $RG_ID

# Create the AKS cluster with autoscale enabled
# Note: For demo purposes we'll set the scale down
# delay and unneeded time to speed up autoscale down time
az aks create -g $RG \
-n $CLUSTER_NAME \
--nodepool-name agentpool1 \
--node-count 1 \
--host-group-id $HOST_GROUP_ID \
--node-vm-size Standard_D2s_v3 \
--zones 1 \
--enable-managed-identity \
--assign-identity $CLUSTER_IDENT_ID \
--enable-cluster-autoscaler \
--min-count 1 \
--max-count 5 \
--cluster-autoscaler-profile scale-down-delay-after-add=1m scale-down-unneeded-time=1m

# Enable Deallocation based scale down on the nodepool
az aks nodepool update -g $RG --cluster-name $CLUSTER_NAME -n agentpool1 --scale-down-mode Deallocate

# Get the cluster credentials
az aks get-credentials -g $RG -n $CLUSTER_NAME

# Deploy the workload to trigger autoscale
kubectl apply -f deploy.yaml

# Watch the cluster scale up to meet demand

# Delete the workload
kubectl delete -f deploy.yaml

# Watch the cluster scale back down
# Note: With deallocation mode you'll see the nodes go into 'NotReady' state, like below
NAME                                      STATUS     ROLES   AGE   VERSION   INTERNAL-IP   EXTERNAL-IP   OS-IMAGE             KERNEL-VERSION     CONTAINER-RUNTIME
node/aks-agentpool1-14380728-vmss000000   Ready      agent   69m   v1.22.6   10.224.0.4    <none>        Ubuntu 18.04.6 LTS   5.4.0-1080-azure   containerd://1.5.11+azure-1
node/aks-agentpool1-14380728-vmss000001   NotReady   agent   65m   v1.22.6   10.224.0.5    <none>        Ubuntu 18.04.6 LTS   5.4.0-1080-azure   containerd://1.5.11+azure-1
node/aks-agentpool1-14380728-vmss000002   NotReady   agent   65m   v1.22.6   10.224.0.6    <none>        Ubuntu 18.04.6 LTS   5.4.0-1080-azure   containerd://1.5.11+azure-1
node/aks-agentpool1-14380728-vmss000003   NotReady   agent   65m   v1.22.6   10.224.0.7    <none>        Ubuntu 18.04.6 LTS   5.4.0-1080-azure   containerd://1.5.11+azure-1
node/aks-agentpool1-14380728-vmss000004   NotReady   agent   21m   v1.22.6   10.224.0.8    <none>        Ubuntu 18.04.6 LTS   5.4.0-1080-azure   containerd://1.5.11+azure-1

