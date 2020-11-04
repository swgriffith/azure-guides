# iptables: Kubenet vs. Azure CNI

## Overview

We've seen the network wiring for both [kubenet](./part1-kubenet.md) and [Azure CNI](./part2-azurecni.md), so now we understand the core plumbing used to move packets around within an AKS cluster. There is one more layer that comes into play, however. As packets arrive on a host, the linux kernel will pass them through iptables to apply filtering (ex. Firewalls) and routing rules. Today, iptables is the default implementation for AKS in cluster routing. IPVS has been considered, as noted on the [intro doc](README.md), but as of yet there hasn't been enough clear need to outweigh the stability and maturity of iptables. Check out AKS issue [#1846](https://github.com/Azure/AKS/issues/1846) for details, and to share your thoughts.

We're not going to go deep into how iptables work in this discussion, but there are plenty of good resources you can use to get up to speed at various levels of detail. I personaly always love the arch linux docs when it comes to linux feature & utility explanations. Check out [this](https://wiki.archlinux.org/index.php/iptables) guide from the arch linux project.

## iptables in kubenet

Lets start by jumping back to our kubenet cluster, connecting to a node over ssh, and taking a look at the iptables entries over there. I'd recommend you read up on iptables and then run the following two commands and start to work through the chains to see if you can figure out whats going on. We'll only be reading these tables, not trying to apply any changes.

```
# List the chains and rules at a high level
sudo iptables -nvL

# List the chains and rules associated with the nat table
sudo iptables -t nat -nvL
```

As you ran through the output of the 'nat' table rules, a few things may have jumped out at you.

1. We seem to have a KUBE-SERVICE chain that contains all of the services on our cluster. Check out the end of line comments for each rule and you should be able to see the specific service name.

1. Our KUBE-SERVICE rules reference a KUBE-SVC-XXXX chain with it's own rules.

1. The individual rules within the KUBE-SVC chain point to a KUBE-SEP-XXXXX chain.

1. The KUBE-SEP-XXXX chain have a rule that points to the ip, port and protocol we exposed from our container

Let's walk through this.

### KUBE-SERVICES

```
# Get the nat table chains and rules
sudo iptables -t nat -nvL KUBE-SERVICES

Chain KUBE-SERVICES (2 references)
 pkts bytes target     prot opt in     out     source               destination
    0     0 KUBE-MARK-MASQ  tcp  --  *      *      !10.100.0.0/16        10.200.0.1           /* default/kubernetes:https cluster IP */ tcp dpt:443
    0     0 KUBE-SVC-NPX46M4PTMTKRN6Y  tcp  --  *      *       0.0.0.0/0            10.200.0.1           /* default/kubernetes:https cluster IP */ tcp dpt:443
    0     0 KUBE-MARK-MASQ  udp  --  *      *      !10.100.0.0/16        10.200.0.10          /* kube-system/kube-dns:dns cluster IP */ udp dpt:53
    0     0 KUBE-SVC-TCOU7JCQXEZGVUNU  udp  --  *      *       0.0.0.0/0            10.200.0.10          /* kube-system/kube-dns:dns cluster IP */ udp dpt:53
    0     0 KUBE-MARK-MASQ  tcp  --  *      *      !10.100.0.0/16        10.200.0.10          /* kube-system/kube-dns:dns-tcp cluster IP */ tcp dpt:53
    0     0 KUBE-SVC-ERIFXISQEP7F7OF4  tcp  --  *      *       0.0.0.0/0            10.200.0.10          /* kube-system/kube-dns:dns-tcp cluster IP */ tcp dpt:53
    0     0 KUBE-MARK-MASQ  tcp  --  *      *      !10.100.0.0/16        10.200.184.192       /* default/nginx: cluster IP */ tcp dpt:80
    0     0 KUBE-SVC-4N57TFCL4MD7ZTDA  tcp  --  *      *       0.0.0.0/0            10.200.184.192       /* default/nginx: cluster IP */ tcp dpt:80
    0     0 KUBE-MARK-MASQ  tcp  --  *      *      !10.100.0.0/16        10.200.219.195       /* kube-system/metrics-server: cluster IP */ tcp dpt:443
    0     0 KUBE-SVC-LC5QY66VUV2HJ6WZ  tcp  --  *      *       0.0.0.0/0            10.200.219.195       /* kube-system/metrics-server: cluster IP */ tcp dpt:443
    0     0 KUBE-MARK-MASQ  tcp  --  *      *      !10.100.0.0/16        10.200.200.30        /* kube-system/kubernetes-dashboard: cluster IP */ tcp dpt:443
    0     0 KUBE-SVC-XGLOHA7QRQ3V22RZ  tcp  --  *      *       0.0.0.0/0            10.200.200.30        /* kube-system/kubernetes-dashboard: cluster IP */ tcp dpt:443
    0     0 KUBE-MARK-MASQ  tcp  --  *      *      !10.100.0.0/16        10.200.143.153       /* kube-system/dashboard-metrics-scraper: cluster IP */ tcp dpt:8000
    0     0 KUBE-SVC-O33EAQYCTNTKHSTD  tcp  --  *      *       0.0.0.0/0            10.200.143.153       /* kube-system/dashboard-metrics-scraper: cluster IP */ tcp dpt:8000
    9   540 KUBE-NODEPORTS  all  --  *      *       0.0.0.0/0            0.0.0.0/0            /* kubernetes service nodeports; NOTE: this must be the last rule in this chain */ ADDRTYPE match dst-type LOCAL

# Grab the rules just for the nginx service
sudo iptables -t nat -nvL KUBE-SERVICES|grep nginx
0     0 KUBE-MARK-MASQ  tcp  --  *      *      !10.100.0.0/16        10.200.184.192       /* default/nginx: cluster IP */ tcp dpt:80
0     0 KUBE-SVC-4N57TFCL4MD7ZTDA  tcp  --  *      *       0.0.0.0/0            10.200.184.192       /* default/nginx: cluster IP */ tcp dpt:80
```

In the above output, as already mentioned you'll see that we have a rule in the KUBE-SERVICES chain for each service in our cluster.  That's right....cluster level, not node level. You can see that by looking at the code comment for each, which shows the namespace and service name. If we look specifically at the nginx service, you can see that we have two rules.

1. **KUBE-MARK-MASQ:** If you look closely you can see that this rule checks if the source is NOT 10.100.0.0/16, which happens to be our pod cidr, and then sends that traffice to the KUBE-MARK-MASQ chain. This is where packets have a mark applied to them to indicate they should go through Source NAT.

1. **KUBE-SVC-XXXX:** This is the chain that handles loadbalancing of the traffic across multiple backend pods

### KUBE-SVC-XXXX

```
# Using the name of our nginx KUBE-SVC chain, lets pull that detail
sudo iptables -t nat -nvL KUBE-SVC-4N57TFCL4MD7ZTDA

Chain KUBE-SVC-4N57TFCL4MD7ZTDA (1 references)
 pkts bytes target     prot opt in     out     source               destination
    0     0 KUBE-SEP-66QNMC7FITAI6UHV  all  --  *      *       0.0.0.0/0            0.0.0.0/0            statistic mode random probability 0.33333333349
    0     0 KUBE-SEP-D27HGEPMBQMIMSQA  all  --  *      *       0.0.0.0/0            0.0.0.0/0            statistic mode random probability 0.50000000000
    0     0 KUBE-SEP-CP6YF2KE7E2OKMTG  all  --  *      *       0.0.0.0/0            0.0.0.0/0
```

Looking at the above, we can see that we have three rules, each pointing to a chain called 'KUBE-SEP-XXXX'. We also see a probability added to the end of each rule. This is how the service traffic will be load balanced. These rules execute in order, so it looks like the following:

1. Hit the first rule which says to send the packet to the KUBE-SEP-66QNMC7FITAI6UHV chain with a probability of 0.33333333349 (33%)

1. If the the packet wasnt sent to KUBE-SEP-66QNMC7FITAI6UHV then this rule says to apply another probability (50 % now because there are only two pods left) which will send to KUBE-SEP-D27HGEPMBQMIMSQA

1. If neither of the above probabilities hit, send the rest of the traffic to KUBE-SEP-CP6YF2KE7E2OKMTG

If we were to scale up the service, we can see this chain get adjusted to a new set of probabilties.

```
# Scale down to two
# Note: Since this deployment uses topology constraints to span nodes
# if you scale up on a three node cluster your new pod will go 'pending'
# so we'll scale down for now
kubectl scale deployment nginx --replicas=2

# Grap the iptaples for the KUBE-SVC chain again
sudo iptables -t nat -nvL KUBE-SVC-4N57TFCL4MD7ZTDA

Chain KUBE-SVC-4N57TFCL4MD7ZTDA (1 references)
 pkts bytes target     prot opt in     out     source               destination
    0     0 KUBE-SEP-66QNMC7FITAI6UHV  all  --  *      *       0.0.0.0/0            0.0.0.0/0            statistic mode random probability 0.50000000000
    0     0 KUBE-SEP-CP6YF2KE7E2OKMTG  all  --  *      *       0.0.0.0/0            0.0.0.0/0
```

Notice in the above that we only have two rules now with a 50% probability applied on the first rule?

> **Note:** The above demonstrates the reason many people look towards IPVS, Cillium, and other network plugins. Probability based routing isnt always ideal. You can modify this behavior a bit by modifying the [External Traffic Policy](https://kubernetes.io/docs/tasks/access-application-cluster/create-external-load-balancer/#preserving-the-client-source-ip). You can also look at the more advanced routing options provided by an ingress controller (ex. Nginx [load-balance](https://kubernetes.github.io/ingress-nginx/user-guide/nginx-configuration/annotations/#custom-nginx-load-balancing) annotation)

### KUBE-SEP-XXX

So now lets check out the KUBE-SEP chain. Not exactly sure what 'SEP' stands for, but one of these days I'll dig into the docs and find it. Feel free to PR the details there. Let's have a look.

```
# Grab one of the KUBE-SEP-XXXX names from the KUBE-SVC-XXXX chain and then pull the chain details
sudo iptables -t nat -nvL KUBE-SEP-66QNMC7FITAI6UHV

Chain KUBE-SEP-66QNMC7FITAI6UHV (1 references)
 pkts bytes target     prot opt in     out     source               destination
    0     0 KUBE-MARK-MASQ  all  --  *      *       10.100.0.9           0.0.0.0/0
    0     0 DNAT       tcp  --  *      *       0.0.0.0/0            0.0.0.0/0            tcp to:10.100.0.9:80
```

In the above, we can finally see the last two rules applied. 

1. KUBE-MARK-MASQ - Again see that outbound traffic from the pod IP (10.100.0.9) should go through the KUBE-MARK-MASQ chain were SNAT will take place for destination 0.0.0.0/0.

1. DNAT - This is where the packet IP is tweaked to finally provide the target IP for the pod. In this case we'll send the traffic to the pod with an ip of 10.100.0.9 at port 80 over tcp. Looking below we can see that the ip referenced in this rule will send traffic to the pod named 'nginx-7cf567cc7-8bt8r'

```
kubectl get pods -o wide

NAME                    READY   STATUS    RESTARTS   AGE     IP           NODE                                NOMINATED NODE   READINESS GATES
nginx-7cf567cc7-8bt8r   1/1     Running   0          3h22m   10.100.0.9   aks-nodepool1-27511634-vmss000000   <none>           <none>
nginx-7cf567cc7-jnxp4   1/1     Running   0          3h22m   10.100.2.2   aks-nodepool1-27511634-vmss000001   <none>           <none>
```

## iptables in Azure CNI

So we've seen how iptables handles traffic for pods in kubenet, so lets run through the same path for an Azure CNI node. Go ahead and ssh to one of your Azure CNI cluster nodes and take a look at the high level rules like we did for kubenet, and then we'll walk through at a lower level.

```
# List the chains and rules at a high level
sudo iptables -nvL

# List the chains and rules associated with the nat table
sudo iptables -t nat -nvL
```

You'll see after running the above, that overall things look pretty similar. There is one additional chain called IP-MASQ-AGENT that we should take a look at in a bit.

### KUBE-SERVICES

```
# Get the nat table chains and rules
sudo iptables -t nat -nvL KUBE-SERVICES

Chain KUBE-SERVICES (2 references)
 pkts bytes target     prot opt in     out     source               destination
    0     0 KUBE-MARK-MASQ  tcp  --  *      *      !10.220.2.0/24        10.200.211.157       /* default/nginx: cluster IP */ tcp dpt:80
    0     0 KUBE-SVC-4N57TFCL4MD7ZTDA  tcp  --  *      *       0.0.0.0/0            10.200.211.157       /* default/nginx: cluster IP */ tcp dpt:80
    0     0 KUBE-MARK-MASQ  udp  --  *      *      !10.220.2.0/24        10.200.0.10          /* kube-system/kube-dns:dns cluster IP */ udp dpt:53
    6   628 KUBE-SVC-TCOU7JCQXEZGVUNU  udp  --  *      *       0.0.0.0/0            10.200.0.10          /* kube-system/kube-dns:dns cluster IP */ udp dpt:53
    0     0 KUBE-MARK-MASQ  tcp  --  *      *      !10.220.2.0/24        10.200.0.10          /* kube-system/kube-dns:dns-tcp cluster IP */ tcp dpt:53
    0     0 KUBE-SVC-ERIFXISQEP7F7OF4  tcp  --  *      *       0.0.0.0/0            10.200.0.10          /* kube-system/kube-dns:dns-tcp cluster IP */ tcp dpt:53
    0     0 KUBE-MARK-MASQ  tcp  --  *      *      !10.220.2.0/24        10.200.239.189       /* kube-system/metrics-server: cluster IP */ tcp dpt:443
    0     0 KUBE-SVC-LC5QY66VUV2HJ6WZ  tcp  --  *      *       0.0.0.0/0            10.200.239.189       /* kube-system/metrics-server: cluster IP */ tcp dpt:443
    0     0 KUBE-MARK-MASQ  tcp  --  *      *      !10.220.2.0/24        10.200.75.15         /* kube-system/kubernetes-dashboard: cluster IP */ tcp dpt:443
    0     0 KUBE-SVC-XGLOHA7QRQ3V22RZ  tcp  --  *      *       0.0.0.0/0            10.200.75.15         /* kube-system/kubernetes-dashboard: cluster IP */ tcp dpt:443
    0     0 KUBE-MARK-MASQ  tcp  --  *      *      !10.220.2.0/24        10.200.191.59        /* kube-system/dashboard-metrics-scraper: cluster IP */ tcp dpt:8000
    0     0 KUBE-SVC-O33EAQYCTNTKHSTD  tcp  --  *      *       0.0.0.0/0            10.200.191.59        /* kube-system/dashboard-metrics-scraper: cluster IP */ tcp dpt:8000
    0     0 KUBE-MARK-MASQ  tcp  --  *      *      !10.220.2.0/24        10.200.0.1           /* default/kubernetes:https cluster IP */ tcp dpt:443
    0     0 KUBE-SVC-NPX46M4PTMTKRN6Y  tcp  --  *      *       0.0.0.0/0            10.200.0.1           /* default/kubernetes:https cluster IP */ tcp dpt:443
   20  1200 KUBE-NODEPORTS  all  --  *      *       0.0.0.0/0            0.0.0.0/0            /* kubernetes service nodeports; NOTE: this must be the last rule in this chain */ ADDRTYPE match dst-type LOCAL

# Grab the rules just for the nginx service
sudo iptables -t nat -nvL KUBE-SERVICES|grep nginx

0     0 KUBE-MARK-MASQ  tcp  --  *      *      !10.220.2.0/24        10.200.211.157       /* default/nginx: cluster IP */ tcp dpt:80
0     0 KUBE-SVC-4N57TFCL4MD7ZTDA  tcp  --  *      *       0.0.0.0/0            10.200.211.157       /* default/nginx: cluster IP */ tcp dpt:80
```

So this looks pretty much exactly the same. Looking at the rules we have....

1. **KUBE-MARK-MASQ:** Yet again, we see that if traffic is coming from a location other than the pod cidr, which in the Azure CNI case is the same as the subnet cidr....that traffic will get sent to the KUBE-MARK-MASQ chain, which as mentioned above, will mark the packet so that it can go through Source NAT later.

1. **KUBE-SVC-XXXX:** This rule, as with kubenet, will send any traffic destined for our service IP address to the KUBE-SVC-XXXX chain.

### KUBE-SVC-XXXX

```
# Using the name of our nginx KUBE-SVC chain, lets pull that detail
sudo iptables -t nat -nvL KUBE-SVC-4N57TFCL4MD7ZTDA

Chain KUBE-SVC-4N57TFCL4MD7ZTDA (1 references)
 pkts bytes target     prot opt in     out     source               destination
    0     0 KUBE-SEP-3OT3PH67SPCSYRVE  all  --  *      *       0.0.0.0/0            0.0.0.0/0            statistic mode random probability 0.33333333349
    0     0 KUBE-SEP-E4OJANFAINTG7AV5  all  --  *      *       0.0.0.0/0            0.0.0.0/0            statistic mode random probability 0.50000000000
    0     0 KUBE-SEP-JNUYOJDTS3SCVUAH  all  --  *      *       0.0.0.0/0            0.0.0.0/0
```

The behavior of the KUBE-SVC-XXXX chain is identical to the same chain in kubenet, so I wont run through that again.

### KUBE-SEP-XXXX

```
# Using the name of one of the KUBE-SEP-XXXX chains, lets pull that detail
sudo iptables -t nat -nvL KUBE-SEP-3OT3PH67SPCSYRVE

Chain KUBE-SEP-3OT3PH67SPCSYRVE (1 references)
 pkts bytes target     prot opt in     out     source               destination
    0     0 KUBE-MARK-MASQ  all  --  *      *       10.220.2.28          0.0.0.0/0
    0     0 DNAT       tcp  --  *      *       0.0.0.0/0            0.0.0.0/0            tcp to:10.220.2.28:80
```

Again, this is effectively identical to the path taken for kubenet, so no reason to go over that again.

I did mention above that there is one additional chain we should look at that is not present in kubenet. It's called IP-MASQ-AGENT and it's triggered in the POST-ROUTINGas one of the very last steps as packets are leaving the cluster. Lets check this one out.

### IP-MASQ-AGENT

As noted above the IP-MASQ-AGENT chain is called by the POSTROUTING chain, as you can see below.

```
sudo iptables -t nat -nvL POSTROUTING

Chain POSTROUTING (policy ACCEPT 0 packets, 0 bytes)
 pkts bytes target     prot opt in     out     source               destination
14204  860K KUBE-POSTROUTING  all  --  *      *       0.0.0.0/0            0.0.0.0/0            /* kubernetes postrouting rules */
    0     0 MASQUERADE  all  --  *      !docker0  172.17.0.0/16        0.0.0.0/0
14190  860K IP-MASQ-AGENT  all  --  *      *       0.0.0.0/0            0.0.0.0/0            /* ip-masq-agent: ensure nat POSTROUTING directs all non-LOCAL destination traffic to our custom IP-MASQ-AGENT chain */ ADDRTYPE match dst-type !LOCAL
```

Now lets look at what it does.

```
sudo iptables -t nat -nvL IP-MASQ-AGENT

Chain IP-MASQ-AGENT (1 references)
 pkts bytes target     prot opt in     out     source               destination
    0     0 RETURN     all  --  *      *       0.0.0.0/0            10.220.0.0/16        /* ip-masq-agent: local traffic is not subject to MASQUERADE */
    0     0 RETURN     all  --  *      *       0.0.0.0/0            10.220.2.0/24        /* ip-masq-agent: local traffic is not subject to MASQUERADE */
    0     0 RETURN     all  --  *      *       0.0.0.0/0            10.200.0.0/16        /* ip-masq-agent: local traffic is not subject to MASQUERADE */
   14   911 MASQUERADE  all  --  *      *       0.0.0.0/0            0.0.0.0/0            /* ip-masq-agent: outbound traffic is subject to MASQUERADE (must be last in chain) */
```

Ok, so for any source (0.0.0.0/0) if the destination is 10.220.0.0/16 (vnet cidr) or 10.220.2.0/24 (subnet cidr) or 10.200.0.0/16 (service cidr) the traffic should go to the RETURN chain....which basically means that it should just go out as is. However, if none of those rules hit (i.e. the traffic is not destined for the vnet, subnet or a service in the cluster) the traffic SHOULD go to the MASQUERADE chain, where we know from above that it will go through Source NAT, which will set the source IP to the node IP.

That's interesting. So only traffic within the vnet will really ever see the pod IP, which is good to know when you start thinking about Network Security Rules, network appliances, firewalls, etc.

I wonder if we can change those settings. It does mention an ip-masq-agent, so lets see if we can find it.

```
# Lets check for any ip-masq pods in kube-system
kubectl get pods -n kube-system -o wide|grep ip-masq
azure-ip-masq-agent-g2dsn                    1/1     Running   0          4h52m   10.220.2.4    aks-nodepool1-44430483-vmss000000   <none>           <none>
azure-ip-masq-agent-j27xx                    1/1     Running   0          4h53m   10.220.2.66   aks-nodepool1-44430483-vmss000002   <none>           <none>
azure-ip-masq-agent-t5cpl                    1/1     Running   0          4h53m   10.220.2.35   aks-nodepool1-44430483-vmss000001   <none>           <none>

# Now lets see if there are configmaps we can look at
kubectl get configmaps -n kube-system|grep ip-masq
azure-ip-masq-agent-config           1      4h55m
```

Yup...there it is along with a config map. Lets check that out.

```
kubectl get configmap azure-ip-masq-agent-config -n kube-system -o yaml
apiVersion: v1
data:
  ip-masq-agent: |-
    nonMasqueradeCIDRs:
      - 10.220.0.0/16
      - 10.220.2.0/24
      - 10.200.0.0/16
    masqLinkLocal: true
    resyncInterval: 60s
kind: ConfigMap
```

Great! There it is. So it looks like we may be able to modify the nonMasqueradeCIDRs to add some cidr blocks. Lets give it a try.

```
# Edit the config map and add a row to the nonMasqueradeCIDRS
# I know...kubectl edit is evil...but we're just playing around here
kubectl edit configmap azure-ip-masq-agent-config -n kube-system

# Check the config
kubectl get configmap azure-ip-masq-agent-config -n kube-system -o yaml
apiVersion: v1
data:
  ip-masq-agent: |-
    nonMasqueradeCIDRs:
      - 10.220.0.0/16
      - 10.220.2.0/24
      - 10.200.0.0/16
      - 10.1.0.0/16

# Now lets see if that impacted our iptables
sudo iptables -t nat -nvL IP-MASQ-AGENT

Chain IP-MASQ-AGENT (1 references)
 pkts bytes target     prot opt in     out     source               destination
    0     0 RETURN     all  --  *      *       0.0.0.0/0            10.220.0.0/16        /* ip-masq-agent: local traffic is not subject to MASQUERADE */
    0     0 RETURN     all  --  *      *       0.0.0.0/0            10.220.2.0/24        /* ip-masq-agent: local traffic is not subject to MASQUERADE */
    0     0 RETURN     all  --  *      *       0.0.0.0/0            10.200.0.0/16        /* ip-masq-agent: local traffic is not subject to MASQUERADE */
    0     0 RETURN     all  --  *      *       0.0.0.0/0            10.1.0.0/16          /* ip-masq-agent: local traffic is not subject to MASQUERADE */
```

Yup! We now have a new cidr block that will NOT go through SNAT.

> **WARNING:** While with the above you can make sure that traffic leaving your vnet does not go through SNAT, depending on the target and potential virtual appliances in the middle you may end up getting your traffic dropped. The overall details of a pod packet may not match what is expected from a machine, and therefor may not be treated like machine traffic. Proceed with caution.

## Conclusion

Hopefully the above helped you understand the overall role that iptables play in both the kubnet and Azure CNI network plugin deployments. As you can see, overall they're almost identical.