#!/bin/bash

RG=EphCoreDNS2
LOC=eastus
CLUSTER_NAME=coredns2
az group create -n $RG -l $LOC

az aks create -g $RG -n $CLUSTER_NAME -c 1

az aks get-credentials -g $RG -n $CLUSTER_NAME

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: dnsutils
  namespace: default
spec:
  containers:
  - name: dnsutils
    image: gcr.io/kubernetes-e2e-test-images/dnsutils:1.3
    command:
      - sleep
      - "3600"
    imagePullPolicy: IfNotPresent
  restartPolicy: Always
EOF

# Lookup a service by name and FQDN
kubectl exec -it dnsutils -- nslookup kubernetes
# Example Output
# Server:		10.0.0.10
# Address:	10.0.0.10#53

# Name:	kubernetes.default.svc.cluster.local
# Address: 10.0.0.1

kubectl exec -it dnsutils -- nslookup kubernetes.default.svc.cluster.local
# Example Output
# Server:		10.0.0.10
# Address:	10.0.0.10#53

# Name:	kubernetes.default.svc.cluster.local
# Address: 10.0.0.1

#############################################################
# AKS Core DNS Config Examples
# https://docs.microsoft.com/en-us/azure/aks/coredns-custom
#############################################################

# Enable Core DNS Logging
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns-custom
  namespace: kube-system
data:
  log.override: | # you may select any name here, but it must end with the .override file extension
        log
EOF

# Restart CoreDNS Pods
kubectl delete pods -l k8s-app=kube-dns -n kube-system

# Follow the core DNS Logs
kubectl logs -l k8s-app=kube-dns -n kube-system -f

# In another window run some DNS querries from within the cluster and watch the logs
kubectl exec -it dnsutils -- nslookup kubernetes

# Sample Log Output
# [INFO] 10.244.1.8:49079 - 14177 "A IN kubernetes.default.svc.cluster.local. udp 54 false 512" NOERROR qr,aa,rd 106 0.000172001s
# [INFO] 10.244.1.8:37483 - 16534 "AAAA IN kubernetes.default.svc.cluster.local. udp 54 false 512" NOERROR qr,aa,rd 147 0.000112101s

# Now resolve an external address
kubectl exec -it dnsutils -- nslookup www.microsoft.com

# Sample Output - Notice that core DNS first tries to resolve within
# the cluster and then passes the request on? Thats because we didnt
# end with a . (ex. microsoft.com. )...so it doesnt know if its an FQDN

# [INFO] 10.244.1.8:52425 - 27879 "A IN www.microsoft.com.default.svc.cluster.local. udp 61 false 512" NXDOMAIN qr,aa,rd 154 0.000177002s
# [INFO] 10.244.1.8:33549 - 26083 "A IN www.microsoft.com.svc.cluster.local. udp 53 false 512" NXDOMAIN qr,aa,rd 146 0.000158901s
# [INFO] 10.244.1.8:47700 - 6896 "A IN www.microsoft.com.cluster.local. udp 49 false 512" NXDOMAIN qr,aa,rd 142 0.000101202s
# [INFO] 10.244.1.8:55643 - 43997 "A IN www.microsoft.com.2qhnno24iy2u1ak0e4r4e45mzd.bx.internal.cloudapp.net. udp 87 false 512" NXDOMAIN qr,rd,ra 208 0.005039456s
# [INFO] 10.244.1.8:46239 - 6683 "A IN www.microsoft.com. udp 35 false 512" NOERROR qr,rd,ra 351 0.002083623s
# [INFO] 10.244.1.8:37242 - 52916 "AAAA IN e13678.dscb.akamaiedge.net. udp 44 false 512" NOERROR qr,rd,ra 325 0.002092923s

# Break the Internet!
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns-custom
  namespace: kube-system
data:
  log.override: | 
        log
  breakaol.server: | 
    aol.com:53 {
        errors
        cache 30
        forward . 1.2.3.4
    }     
EOF

# Restart CoreDNS
kubectl delete pods -l k8s-app=kube-dns -n kube-system

# Follow the logs
kubectl logs -l k8s-app=kube-dns -n kube-system -f

# Test resolution
kubectl exec -it dnsutils -- nslookup aol.com.
kubectl exec -it dnsutils -- nslookup google.com.

###############################################################
# In the above you should have scene aol.com. timeout trying
# to find the 1.2.3.4 DNS server, while google.com. still works
################################################################


cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns-custom
  namespace: kube-system
data:
  log.override: | 
        log   
EOF