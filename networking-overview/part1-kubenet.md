
# AKS Networking Overview - Part 1: Kubenet

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

Notice the eth0 is @if19, meaning its attached to interface 19, but what is that? If we take a look at the host machine interfaces we can see that there is an interface with the index of 19 named "vethd3b9c108@if3" as you can see in the image below, @if3 and @if19 are the link between the container network interface and the host network interface, which happens to be a veth link.

![veth link](./images/vethlink.png)

Ok, so now we know how each container is connected to the a virtual ethernet interface on the host, but where does it get it's IP and how does it communicate out of the node? Our first hint is the 'cbr0' name listed in the 'ip addr' output for our veth.  Checking out the Kubernetes docs on kubenet, we know that cbr0 is the bridge network created and managed by kubenct. We can see the interface in our 'ip addr' output. Also notice that the inet value for cbr0 is 10.100.1.1/24, which happens to be our pod cidr! So cbr0 is the bridge network that the veth links are joined to. We can confirm this by using the brctl command from bridge-utils. Notice all of our veth interfaces attached to cbr0.

```bash
# Install the bridge-utils package
sudo apt update
sudo apt install bridge-utils

# Show the bridge networks on the server
brctl show
bridge name bridge id          STP enabled  interfaces
cbr0        8000.160c0cac5660  no           veth9423965c
                                            vetha1065ff2
                                            vetha33f314e
                                            vethcd3ab008
                                            vethd3b9c108
```

Further, if we look at the routes defined on our machine we can see that any traffic destined for our pod cidr should be sent to that cbr0 bridge interface.

```bash
# Get Routes
route -n
Kernel IP routing table
Destination     Gateway         Genmask         Flags Metric Ref    Use Iface
0.0.0.0         10.220.1.1      0.0.0.0         UG    0      0        0 eth0
10.100.1.0      0.0.0.0         255.255.255.0   U     0      0        0 cbr0
10.220.1.0      0.0.0.0         255.255.255.0   U     0      0        0 eth0
168.63.129.16   10.220.1.1      255.255.255.255 UGH   0      0        0 eth0
169.254.169.254 10.220.1.1      255.255.255.255 UGH   0      0        0 eth0
172.17.0.0      0.0.0.0         255.255.0.0     U     0      0        0 docker0
```


## References
* [Understanding Azure Kubernetes Service
Basic Networking](https://azuregulfblog.files.wordpress.com/2019/04/aks_basicnetwork_technicalpaper.pdf)