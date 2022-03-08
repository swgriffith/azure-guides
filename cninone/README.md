# AKS CNI = None

https://github.com/Azure/AKS/issues/2092

## Calico CNI Install

```bash
# Create the cluster
RG=EphCNISession
LOC=eastus
CLUSTER_NAME=calico-cni
VNET_SUBNET_ID=<insert vnet subnet id>

az group create -n $RG -l $LOC
az aks create -g $RG -n $CLUSTER_NAME \
--network-plugin none \
--vnet-subnet-id $VNET_SUBNET_ID

# Install Calico CNI
kubectl apply -f https://raw.githubusercontent.com/mattstam/cni-examples/master/calico/v3-20-0/operator-base.yaml
kubectl apply -f https://raw.githubusercontent.com/mattstam/cni-examples/master/calico/v3-20-0/install-vxlan.yaml
```

## Cilium CNI Install

```bash
RG=EphCNISession
LOC=eastus
CLUSTER_NAME=cilium-cni
VNET_SUBNET_ID=<insert vnet subnet id>

az group create -n $RG -l $LOC
az aks create -g $RG -n $CLUSTER_NAME \
--network-plugin none \
--vnet-subnet-id $VNET_SUBNET_ID

# Install Cilium CNI
kubectl create -f https://raw.githubusercontent.com/cilium/cilium/v1.9/install/kubernetes/quick-install.yaml

# Test Cilium CNI
kubectl create ns cilium-test
kubectl apply -n cilium-test -f https://raw.githubusercontent.com/cilium/cilium/v1.9/examples/kubernetes/connectivity-check/connectivity-check.yaml

# Install Hubble
export CILIUM_NAMESPACE=kube-system
kubectl apply -f https://raw.githubusercontent.com/cilium/cilium/v1.9/install/kubernetes/quick-hubble-install.yaml

# Browse to Hubble UI
kubectl port-forward -n $CILIUM_NAMESPACE svc/hubble-ui --address 0.0.0.0 --address :: 12000:80
http://localhost:12000/
```