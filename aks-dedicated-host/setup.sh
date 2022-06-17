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
--max-count 5

# Get the cluster credentials
az aks get-credentials -g $RG -n $CLUSTER_NAME

# Deploy the workload to trigger autoscale
kubectl apply -f deploy.yaml

