# AKS Storage Perf Testing

## Host Ephemeral OS Disk Setup

```bash
RG=EphAKSEphemeralStor
LOC=eastus
CLUSTER_NAME=ephstoragetest
SKU=Standard_E32bds_v5
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

# Create the E-series (nvme) test pool
az aks nodepool add \
--resource-group $RG \
--cluster-name $CLUSTER_NAME \
--node-vm-size $SKU \
--node-count 1 \
--name testpool \
--node-osdisk-type Ephemeral \
--enable-ultra-ssd \
--zones 1 \
--mode User

# Get credentials
az aks get-credentials -g $RG -n $CLUSTER_NAME
```

### Run raw nvme device test

SSH to a test node

```bash
# On the node, install fio
sudo apt update;sudo apt install fio -y

# Cormac Test on host and pod with Eph on Temp
fio --name=write_4G --directory=/tmp --direct=1 --size=4G --bs=4M --rw=write --group_reporting --numjobs=4 --runtime=300
sync
echo 3 > /proc/sys/vm/drop_caches
free -h
fio --name=read_4G --directory=/tmp --direct=1 --size=4G --bs=4M --rw=read --group_reporting --numjobs=4 --runtime=300

# Cormac Test on host and pod ultra SSD
fio --name=write_4G --directory=/mnt/azure --direct=1 --size=4G --bs=4M --rw=write --group_reporting --numjobs=4 --runtime=30 --time_based
sync
echo 3 > /proc/sys/vm/drop_caches
free -h
fio --name=read_4G --directory=/mnt/azure --direct=1 --size=4G --bs=4M --rw=read --group_reporting --numjobs=4 --runtime=300

SKU=Standard_D48ads_v5

# Create the E-series (nvme) test pool
az aks nodepool add \
--resource-group $RG \
--cluster-name $CLUSTER_NAME \
--node-vm-size $SKU \
--node-count 1 \
--name testpool \
--node-osdisk-type Ephemeral \
--mode User

fio --name=write_4G --directory=/tmp --direct=1 --size=4G --bs=4M --rw=read --group_reporting --numjobs=4 --runtime=30 --time_based
fio --name=write_4G --directory=/tmp --direct=1 --size=4G --bs=4M --rw=write --group_reporting --numjobs=4 --runtime=30 --time_based

fio --name=write_4G --directory=/mnt --direct=1 --size=4G --bs=4M --rw=read --group_reporting --numjobs=4 --runtime=30 --time_based
fio --name=write_4G --directory=/mnt --direct=1 --size=4G --bs=4M --rw=write --group_reporting --numjobs=4 --runtime=30 --time_based