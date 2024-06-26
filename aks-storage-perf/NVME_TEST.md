# AKS Storage Perf Testing

## Host NVME Setup

```bash
RG=EphAKSStorage
LOC=eastus
CLUSTER_NAME=nvmetest
SKU=Standard_L8as_v3
VNET_SUBNET_ID="/subscriptions/<SUBID>/resourceGroups/networkinfra/providers/Microsoft.Network/virtualNetworks/azure-eastus-vnet/subnets/home-aks"

# Create the resource group
az group create -n $RG -l $LOC

# Create the cluster and system pool
az aks create \
-g $RG \
-n $CLUSTER_NAME \
--nodepool-name systempool \
--node-vm-size Standard_D2_v4 \
--node-count 1 \
--nodepool-taints CriticalAddonsOnly=true:NoSchedule \
--vnet-subnet-id $VNET_SUBNET_ID

# Create the L-series (nvme) test pool
az aks nodepool add \
--resource-group $RG \
--cluster-name $CLUSTER_NAME \
--node-vm-size $SKU \
--node-count 1 \
--name testpool \
--mode User

# Get credentials
az aks get-credentials -g $RG -n $CLUSTER_NAME
```

### Run raw nvme device test

SSH to a node in the NVME pool

```bash
# On the node, install fio
sudo apt update;sudo apt install fio -y

# Create the fio test file
cat << EOF > direct_device.fio
[global]
bs=1M
iodepth=256
direct=1
ioengine=libaio
group_reporting
time_based
runtime=120
numjobs=1
							
[raw-seq-write]
filename=/dev/nvme0n1
rw=write

[raw-seq-read]
filename=/dev/nvme0n1
rw=read

[raw-rand-write]
filename=/dev/nvme0n1
rw=randwrite

[raw-rand-read]
filename=/dev/nvme0n1
rw=randread
EOF

# Run the fio test
sudo fio direct_device.fio

```

## Mount the NVME

```bash
# Deploy the NVME daemonset
kubectl apply -f storage-local-static-provisioner.yaml


```


### Mounted Volume Test

```bash
# Create the fio test file
cat << EOF > mounted_device.fio
[global]
bs=4k
iodepth=256
direct=1
ioengine=libaio
group_reporting
time_based
runtime=120
numjobs=1
							
[raw-seq-write]
filename=/pv-disks/nvme/test.dat
size=10GB
rw=write

[raw-seq-read]
filename=/pv-disks/nvme/test.dat
rw=read

[raw-rand-write]
filename=/pv-disks/nvme/test.dat
size=10GB
rw=randwrite

[raw-rand-read]
filename=/pv-disks/nvme/test.dat
rw=randread
EOF

sudo fio mounted_device.fio
```