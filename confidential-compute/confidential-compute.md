# Intel SGX Confidential Compute on AKS

In this walkthrough we'll set up an AKS cluster with Intel SGX confidential compute enabled, and deploy a sample workload.

## Cluster Setup

```bash
# Set variables
RG=EphIntelSGXConfidential
LOC=eastus
CLUSTER_NAME=intelsgx

# Create Resource Group
az group create -n $RG -l $LOC

# Create cluster with confcom enabled
az aks create -g $RG --name $CLUSTER_NAME \
--enable-addons confcom

# Add the Intel SGX enabled nodepool
az aks nodepool add \
--resource-group $RG \
--cluster-name $CLUSTER_NAME \
--name confcompool \
--node-vm-size Standard_DC4s_v3 \
--node-count 2

az aks get-credentials \
--resource-group $RG \
--name $CLUSTER_NAME

# Check for the SGX plugin
kubectl get pods -l app=sgx-plugin -n kube-system -o wide
```

## Deploy the Intel SGX sample workload

```bash
# Deply the sample app
kubectl apply -f ./manifests/hello-world-enclave.yaml

kubectl get pods

kubectl logs -l app=oe-helloworld

# Sample Output
Hello world from the enclave
Enclave called into host to print: Hello World!
```

## Add and AMD SEV-SNP Nodepool

```bash
az aks nodepool add \
--resource-group $RG \
--cluster-name $CLUSTER_NAME \
--name smdsevdnp \
--node-count 1 \
--node-vm-size Standard_DC4as_v5
```

## Build a python sample app container

```bash

ACR_NAME=griffccdemo

az acr create -g $RG -n $ACR_NAME --sku Standard

# Attach the ACR to the Cluster
az aks update \
-g $RG \
-n $CLUSTER_NAME \
--attach-acr $ACR_NAME


git clone https://github.com/Azure-Samples/confidential-container-samples.git  
cd ./confidential-container-samples/cvm-python-app-remoteattest/
az acr build --registry $ACR_NAME --image cvmattest:v1 .
kubectl apply -f "k8sdeploy.yaml" --validate=false 
kubectl get svc azure-cvm-attest -w
```