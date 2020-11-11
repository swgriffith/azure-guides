
# AKS Networking Overview - Network Policy Impact on Bridge Mode vs. Transparent

## Overview

In our Azure CNI Overview (check it out [here](./part2-azurecni.md) if you haven't already), we assumed no network policy is deployed on our cluster. When you enable network policy there are a few fundamental changes that are probably worth calling out. I'm going to focus on Calico network policy in AKS, which is implemented using open source Calico.

## Azure CNI

If we take a look at the ['Technical Deep Dive'](https://azure.microsoft.com/en-us/blog/integrating-azure-cni-and-calico-a-technical-deep-dive/) doc for Azure CNI we see that when you implement network policy on a cluster there is one fundamental change. We move from 'bridge mode' to 'transparent mode' networking. What does that actually mean? Well, we can see it very quickly and easily be running either the kubenet or azure cni deployments we already talked about, setting the '--network-policy calico' flag and then running through the same analysis we've already shown in [part1](./part1-kubenet.md) and [part2](./part2-azurecni.md) of our networking overview.

```bash
# We'll re-use the RG and LOC, so lets set those
RG=NetworkLab
LOC=eastus

# Get the Azure CNI Subnet ID
AZURECNI_SUBNET_ID=$(az network vnet show -g $RG -n aksvnet -o tsv --query "subnets[?name=='azurecni'].id")

# Create the same Azure CNI cluster, but with the Calico network plugin
az aks create \
-g $RG \
-n azurecni-cluster \
--network-plugin azure \
--network-policy calico \
--vnet-subnet-id $AZURECNI_SUBNET_ID \
--service-cidr "10.200.0.0/16" \
--dns-service-ip "10.200.0.10" \
--enable-managed-identity

# Deploy 3 Nginx Pods across 3 nodes
kubectl apply -f nginx.yaml

# View the Services and pods
kubectl get svc
kubectl get pods -o wide --sort-by=.spec.nodeName # Sorted by node name
```

Now lets run through the network stack. Again, you'll need to set up ssh access to the node. See part1 or part 2 for details.

```bash
# Get the process id for our nginx deployment
docker inspect 0b7c7a46ade1|grep Pid
            "Pid": 16315,
            "PidMode": "",
            "PidsLimit": null,

# Get the pod interface
sudo nsenter -t 16315 -n ip addr
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN group default qlen 1000
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
    inet 127.0.0.1/8 scope host lo
       valid_lft forever preferred_lft forever
15: eth0@if16: <BROADCAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP group default qlen 1000
    link/ether e6:82:2e:aa:77:ff brd ff:ff:ff:ff:ff:ff link-netnsid 0
    inet 10.220.2.21/24 scope global eth0

# Get the host interfaces (abbreviated)
ip addr
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN group default qlen 1000
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
    inet 127.0.0.1/8 scope host lo
       valid_lft forever preferred_lft forever
    inet6 ::1/128 scope host
       valid_lft forever preferred_lft forever
2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc mq state UP group default qlen 1000
    link/ether 00:0d:3a:9c:96:47 brd ff:ff:ff:ff:ff:ff
    inet 10.220.2.4/24 brd 10.220.2.255 scope global eth0
       valid_lft forever preferred_lft forever
    inet6 fe80::20d:3aff:fe9c:9647/64 scope link
       valid_lft forever preferred_lft forever
.
.
.
16: azv33ac2d062ec@if15: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP group default qlen 1000
    link/ether 92:81:10:67:e0:26 brd ff:ff:ff:ff:ff:ff link-netnsid 4
    inet6 fe80::9081:10ff:fe67:e026/64 scope link
       valid_lft forever preferred_lft forever
```

Notice that we dont have a reference to the 'azure0' bridge that we had in our Azure CNI walk through. Now lets check out the bridge networks and routes.

```bash
sudo apt update
sudo apt install bridge-utils

# Check the bridge networks on the host
brctl show
bridge name bridge id           STP enabled interfaces
docker0     8000.0242107e030e   no

# Check out the routes on the host
route -n
Kernel IP routing table
Destination     Gateway         Genmask         Flags Metric Ref    Use Iface
0.0.0.0         10.220.2.1      0.0.0.0         UG    0      0        0 eth0
10.220.2.0      0.0.0.0         255.255.255.0   U     0      0        0 eth0
10.220.2.8      0.0.0.0         255.255.255.255 UH    0      0        0 azv590e0427f9b
10.220.2.10     0.0.0.0         255.255.255.255 UH    0      0        0 azv5638516250a
10.220.2.16     0.0.0.0         255.255.255.255 UH    0      0        0 azvc6db35c2bf7
10.220.2.21     0.0.0.0         255.255.255.255 UH    0      0        0 azv33ac2d062ec
10.220.2.28     0.0.0.0         255.255.255.255 UH    0      0        0 azva2bb7836522
168.63.129.16   10.220.2.1      255.255.255.255 UGH   0      0        0 eth0
169.254.169.254 10.220.2.1      255.255.255.255 UGH   0      0        0 eth0
172.17.0.0      0.0.0.0         255.255.0.0     U     0      0        0 docker0

```

So you should be able to see the difference pretty quickly. First of all, we don't have any bridge networks, other than the docker bridge. So no 'azure0'. On the flip side, we have far more routes. Specifically, we have a route for EVERY interface, including our 'azv*' veth interfaces. 

### Kubenet

Rather than running through the full setup again, I'll just show you the output of the same set of commands. Lets check out the interfaces, bridges and routes.

```bash
# Check out the pod interface
sudo nsenter -t 30064 -n ip addr
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN group default qlen 1000
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
    inet 127.0.0.1/8 scope host lo
       valid_lft forever preferred_lft forever
3: eth0@if15: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP group default
    link/ether be:26:02:27:b2:cd brd ff:ff:ff:ff:ff:ff link-netnsid 0
    inet 10.244.0.10/32 scope global eth0
       valid_lft forever preferred_lft forever


# Check the host interfaces (abbreviated)
ip addr
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN group default qlen 1000
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
    inet 127.0.0.1/8 scope host lo
       valid_lft forever preferred_lft forever
    inet6 ::1/128 scope host
       valid_lft forever preferred_lft forever
2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc mq state UP group default qlen 1000
    link/ether 00:0d:3a:9c:3c:c1 brd ff:ff:ff:ff:ff:ff
    inet 10.240.0.4/16 brd 10.240.255.255 scope global eth0
       valid_lft forever preferred_lft forever
    inet6 fe80::20d:3aff:fe9c:3cc1/64 scope link
       valid_lft forever preferred_lft forever
3: enP1279s1: <BROADCAST,MULTICAST,SLAVE,UP,LOWER_UP> mtu 1500 qdisc mq master eth0 state UP group default qlen 1000
    link/ether 00:0d:3a:9c:3c:c1 brd ff:ff:ff:ff:ff:ff
4: docker0: <NO-CARRIER,BROADCAST,MULTICAST,UP> mtu 1500 qdisc noqueue state DOWN group default
    link/ether 02:42:98:e2:19:c6 brd ff:ff:ff:ff:ff:ff
    inet 172.17.0.1/16 brd 172.17.255.255 scope global docker0
       valid_lft forever preferred_lft forever
.
.
.
15: cali4cd5cd7d78e@if3: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP group default
    link/ether ee:ee:ee:ee:ee:ee brd ff:ff:ff:ff:ff:ff link-netnsid 8
    inet6 fe80::ecee:eeff:feee:eeee/64 scope link
       valid_lft forever preferred_lft forever

# Look at the bridge networks
brctl show
bridge name bridge id           STP enabled interfaces
docker0     8000.024298e219c6   no

# And finally the routes
route -n
Kernel IP routing table
Destination     Gateway         Genmask         Flags Metric Ref    Use Iface
0.0.0.0         10.240.0.1      0.0.0.0         UG    0      0        0 eth0
10.240.0.0      0.0.0.0         255.255.0.0     U     0      0        0 eth0
10.244.0.2      0.0.0.0         255.255.255.255 UH    0      0        0 cali16fcf5898b5
10.244.0.3      0.0.0.0         255.255.255.255 UH    0      0        0 calidb3c3076a20
10.244.0.4      0.0.0.0         255.255.255.255 UH    0      0        0 calie303d952cb6
10.244.0.5      0.0.0.0         255.255.255.255 UH    0      0        0 calia13e3da9825
10.244.0.6      0.0.0.0         255.255.255.255 UH    0      0        0 cali0b8d4f989c0
10.244.0.7      0.0.0.0         255.255.255.255 UH    0      0        0 calid51803d5b2f
10.244.0.8      0.0.0.0         255.255.255.255 UH    0      0        0 cali84427e61d61
10.244.0.9      0.0.0.0         255.255.255.255 UH    0      0        0 calidc7b59b68d8
10.244.0.10     0.0.0.0         255.255.255.255 UH    0      0        0 cali4cd5cd7d78e
168.63.129.16   10.240.0.1      255.255.255.255 UGH   0      0        0 eth0
169.254.169.254 10.240.0.1      255.255.255.255 UGH   0      0        0 eth0
172.17.0.0      0.0.0.0         255.255.0.0     U     0      0        0 docker0
```

As you can see, once we introduce network policy, we lose the bridge networks and get a bunch of routes added. For kubenet you can also see that our virtual ethernet adapters name changes in kubenet from 'veth*' to 'calic*', which is an indication of Calico taking over the provisioning of those interfaces.

### Conclusion

So across both Kubenet and Azure CNI, once you implement network policy we transition from Bridge Mode to Transparent mode. Based on what we've seen above this essentially translates to the removal of the bridge network (cbr0 or azure0) and the introduction of routes directly on the host to control the packet flow.

### References

* [Azure CNI Technical Deep Dive](https://azure.microsoft.com/en-us/blog/integrating-azure-cni-and-calico-a-technical-deep-dive/)