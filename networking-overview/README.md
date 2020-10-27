# Overview

## Topics

* Network Plugin: Kubenet vs. Azure CNI
  * Dive into Routing and NAT
* Network Policy: None/Azure/Calico
* Outbound Type: Check out the session from [@RayKao](https://twitter.com/raykao)...[here](https://www.youtube.com/channel/UCvdABD6_HuCG_to6kVprdjQ)
* Debugging
  * ssh-jump
  * tcpdump
  * ksniff
* Windows Networking
* IPv6 status
* IPTables vs IPVS

## Setup
For this session we'll create a resource group with a Vnet, three subnets and two AKS Clusters.

### Create Resource Group, Vnet and Subnets

```bash
RG=NetworkLab
LOC=eastus
VNET_CIDR="10.220.0.0/16"
KUBENET_AKS_CIDR="10.220.1.0/24"
AZURECNI_AKS_CIDR="10.220.2.0/24"
SVC_LB_CIDR="10.220.3.0/24"

# Create Resource Group
az group create -n $RG -l $LOC

# Create Vnet
az network vnet create \
-g $RG \
-n aksvnet \
--address-prefix $VNET_CIDR

# Create Kubenet AKS Cluster Subnet
az network vnet subnet create \
    --resource-group $RG \
    --vnet-name aksvnet \
    --name kubenet \
    --address-prefix $KUBENET_AKS_CIDR

# Get the Kubnet Subnet ID
KUBENET_SUBNET_ID=$(az network vnet show -g $RG -n aksvnet -o tsv --query "subnets[?name=='kubenet'].id")

# Create Azure CNI AKS Cluster Subnet
az network vnet subnet create \
    --resource-group $RG \
    --vnet-name aksvnet \
    --name azurecni \
    --address-prefix $AZURECNI_AKS_CIDR

# Get the Kubnet Subnet ID
AZURECNI_SUBNET_ID=$(az network vnet show -g $RG -n aksvnet -o tsv --query "subnets[?name=='azurecni'].id")

# Create the subnet for Kubernetes Service Load Balancers
az network vnet subnet create \
    --resource-group $RG \
    --vnet-name aksvnet \
    --name services \
    --address-prefix $SVC_LB_CIDR 
```

### Create the Kubenet AKS Cluster
```bash
######################################
# Create the Kubenet AKS Cluster
# Note: We set a pod cidr, service cidr
# and dns service ip for demonstration
# purposes, however these are optional
#######################################
az aks create \
-g $RG \
-n kubenet-cluster \
--network-plugin kubenet \
--vnet-subnet-id $KUBENET_SUBNET_ID \
--pod-cidr "10.100.0.0/16" \
--service-cidr "10.200.0.0/16" \
--dns-service-ip "10.200.0.10" \
--enable-managed-identity

# Get Credentials
az aks get-credentials -g $RG -n kubenet-cluster

# Deploy 3 Nginx Pods across 3 nodes
kubectl apply -f nginx.yaml

# View the Services and pods
kubectl get svc
kubectl get pods -o wide --sort-by=.spec.nodeName # Sorted by node name
```

### Pod and Service CIDR behavior

Notice from your get svc and pods calls that the private IP addresses are from the pod and serivce cidr ranges you specified at cluster creation, and not from you subnet cidr.

```bash
# Subnet CIDR from network creation
KUBENET_AKS_CIDR="10.220.1.0/24"

# CIDR Values from 'az aks create'
--pod-cidr "10.100.0.0/16"
--service-cidr "10.200.0.0/16"
```

![Services and Pods](./images/kubenetsvcspods.png)

To dig a bit deeper, lets ssh into the node and explore the network configuration. For this we'll use [ssh-jump](https://github.com/yokawasa/kubectl-plugin-ssh-jump/blob/master/README.md) but there are various other options, including using priviledged containers. If you do ssh to a node, you'll need to [set up ssh access](https://docs.microsoft.com/en-us/azure/aks/ssh).

```bash
# Get a node name and ssh-jump to it
# Make sure you jump to a node where one of your nginx pods is running
kubectl get nodes
NAME                                STATUS   ROLES   AGE    VERSION
aks-nodepool1-27511634-vmss000000   Ready    agent   4d3h   v1.17.11
aks-nodepool1-27511634-vmss000001   Ready    agent   4d3h   v1.17.11
aks-nodepool1-27511634-vmss000002   Ready    agent   4d3h   v1.17.11

kubectl ssh-jump aks-nodepool1-27511634-vmss000000

# Get the docker id for the nginx pod
kubectl get pods|grep nginx
d01940d20034        nginx                                          "/docker-entrypoint.…"   24 minutes ago      Up 24 minutes                           k8s_nginx_nginx-7cf567cc7-8879g_default_33aa572a-8816-4635-b9c4-be315b270f27_0
660dcdb7ed1c        mcr.microsoft.com/oss/kubernetes/pause:1.3.1   "/pause"                 24 minutes ago      Up 24 minutes                           k8s_POD_nginx-7cf567cc7-8879g_default_33aa572a-8816-4635-b9c4-be315b270f27_0
```

Ok, wait....why do we have two containers for this single nginx pod? Go check out the [the almight pause container](https://www.ianlewis.org/en/almighty-pause-container). In short, the other container is the '/pause' container, which is the parent container for all contianers within a given Kubernetes pod.

```bash
# Get the pid for your container
docker inspect --format '{{ .State.Pid }}' 660dcdb7ed1c

# List the network interfaces for the pid
sudo nsenter -t 14219 -n ip add
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN group default qlen 1000
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
    inet 127.0.0.1/8 scope host lo
       valid_lft forever preferred_lft forever
3: eth0@if19: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP group default
    link/ether a6:89:88:b2:e5:a6 brd ff:ff:ff:ff:ff:ff link-netnsid 0
    inet 10.100.1.14/24 scope global eth0
       valid_lft forever preferred_lft forever
```

Notice the eth0 is @if19, meaning its attached to interface 19, but what is that?

```bash
# Get the host interfaces
ip addr
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN group default qlen 1000
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
    inet 127.0.0.1/8 scope host lo
       valid_lft forever preferred_lft forever
    inet6 ::1/128 scope host
       valid_lft forever preferred_lft forever
2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc mq state UP group default qlen 1000
    link/ether 00:0d:3a:1c:87:a5 brd ff:ff:ff:ff:ff:ff
    inet 10.220.1.4/24 brd 10.220.1.255 scope global eth0
       valid_lft forever preferred_lft forever
    inet6 fe80::20d:3aff:fe1c:87a5/64 scope link
       valid_lft forever preferred_lft forever
  .
  .
  .
19: vethd3b9c108@if3: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue master cbr0 state UP group default
    link/ether 3e:6a:2c:7e:59:25 brd ff:ff:ff:ff:ff:ff link-netnsid 4
    inet6 fe80::3c6a:2cff:fe7e:5925/64 scope link
       valid_lft forever preferred_lft forever
```
