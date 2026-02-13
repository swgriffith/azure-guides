# Containerd NRI on AKS

This guide walks through creating an AKS cluster, verifying NRI (Node Resource Interface) is enabled, and running the containerd NRI OCI Hook Injector example.

## Prerequisites

- Azure CLI installed and configured
- kubectl installed
- Access to an Azure subscription

## Step 1: Create an AKS Cluster

Create a resource group and AKS cluster:

```bash
# Set variables
RESOURCE_GROUP="nri-demo-rg4"
CLUSTER_NAME="nri-example"
LOCATION="eastus2"
NODE_VM_SIZE="standard_d4_v4"

# Create resource group
az group create --name $RESOURCE_GROUP --location $LOCATION

# Create AKS cluster with Ubuntu 24.04 (containerd 2.0 has NRI enabled by default)
az aks create \
  --resource-group $RESOURCE_GROUP \
  --name $CLUSTER_NAME \
  --node-count 1 \
  --node-vm-size $NODE_VM_SIZE \
  --os-sku Ubuntu2404 \
  --generate-ssh-keys

# Get credentials
az aks get-credentials --resource-group $RESOURCE_GROUP --name $CLUSTER_NAME
```

## Step 2: Verify NRI is Enabled in Containerd Config

SSH into a node to check the containerd configuration:

```bash
# Get node name
NODE_NAME=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')

# Create a debug pod to access the node
kubectl debug node/$NODE_NAME -it --image=mcr.microsoft.com/cbl-mariner/base/core:2.0
```

Once inside the debug pod, check the containerd config:

```bash
# Switch to host filesystem
chroot /host
bash

# Verify NRI is enabled by checking if the NRI socket exists:
ls -la /var/run/nri/nri.sock
```

Exit the debug pod:

```bash
exit
exit
exit
```

Clean up the debug pod:

```bash
kubectl delete pod $(kubectl get pods | grep node-debugger | awk '{print $1}')
```

## Step 3: Run the NRI OCI Hook Injector Example

The OCI Hook Injector is an NRI plugin that injects OCI hooks into containers. NRI plugins run as host binaries that connect to the NRI socket.

### Deploy the Hook Injector

First, apply the ConfigMaps for the hook configuration and demo script:

```bash
# Apply the hook configuration (defines which hooks to inject)
kubectl apply -f hook-injector.yaml

# Apply the demo hook script
kubectl apply -f demo-hook.yaml
```

Then deploy the hook-injector DaemonSet using kustomize:

```bash
kubectl apply -k hook-injector/
```

Wait for the DaemonSet to be ready:

```bash
kubectl rollout status daemonset/nri-plugin-hook-injector -n kube-system
```

### Test the Hook Injector

Follow the injector pod logs to see when hooks are executed:

```bash
# In one terminal, watch the injector logs
kubectl logs -n kube-system -l app.kubernetes.io/name=nri-plugin-hook-injector -f
```

Create a test pod:

```bash
# In a second terminal, create a test pod that will trigger the hook
kubectl run ubuntupod -it --rm --image=ubuntu -- bash
exit

# You can repeat the above command to create multiple pods and see the hook executed each time.
```

Verify the hook was executed by checking the log file on the node:

```bash
# Get node name
NODE_NAME=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')

# Create a debug pod to access the node
kubectl debug node/$NODE_NAME -it --image=mcr.microsoft.com/cbl-mariner/base/core:2.0

# Inside the debug pod
chroot /host
cat /tmp/demo-hook.log
```

You should see log entries showing the hook was executed for your test pod.

## Cleanup

```bash
# Delete the resource group (includes AKS cluster)
az group delete --name $RESOURCE_GROUP --yes --no-wait
```

## References

- [NRI (Node Resource Interface)](https://github.com/containerd/nri)
- [NRI Hook Injector Plugin](https://github.com/containerd/nri/tree/main/plugins/hook-injector)
- [AKS Documentation](https://learn.microsoft.com/en-us/azure/aks/)
- [Containerd NRI Specification](https://github.com/containerd/containerd/blob/main/docs/NRI.md)
