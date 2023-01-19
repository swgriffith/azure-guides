# AKS Sticky SLB Test Setup

## Cluster Creation

```bash
# Set Env Args
RG=EphSLBTest
LOC=eastus
CLUSTER_NAME=slbtest
NAMESPACE=default

# Create the resource group
az group create -n $RG -l $LOC

# Create the cluster
az aks create -n $CLUSTER_NAME -g $RG 

# Get Cluster Credentials
az aks get-credentials -n $CLUSTER_NAME -g $RG --admin
```

## Deploy the workloads

```bash
# Deploy the echo server pods
kubectl apply -f manifests/echoserver.yaml
```

## Monitor

In one terminal we'll watch the pods as we scale up and down and in the other we'll run a curl command against the echoserver.

> **Note:** We'll start with 2 pods across three nodes, so we can see that the stickiness maintains on scale up. For simplicity we will not go above 3 pods for this test, as kubernetes will evenly distribute pods across the three nodes (i.e. 3 pods on 3 nodes will lead to one pod per node)

Terminal 1:
```bash
watch kubectl get pods -o wide

# Sample Output
Every 2.0s: kubectl get pods -o wide                                                                                         Steves-MBP.localdomain: Thu Jan 19 11:46:26 2023

NAME                          READY   STATUS    RESTARTS   AGE   IP           NODE                                NOMINATED NODE   READINESS GATES
echoserver-59bf4556cd-cdq24   1/1     Running   0          7s    10.244.1.8   aks-nodepool1-19369881-vmss000000   <none>           <none>
echoserver-59bf4556cd-ghvms   1/1     Running   0          7s    10.244.2.8   aks-nodepool1-19369881-vmss000001   <none>           <none>
```

Terminal 2:
```bash
watch curl -sb -H 'Cache-Control: no-cache, no-store' http://20.237.48.44:8080\|grep Hostname

# Sample Output
Every 2.0s: curl -sb -H Cache-Control: no-cache, no-store http://20.237.48.44:8080|grep Hostname                             Steves-MBP.localdomain: Thu Jan 19 11:43:40 2023

Hostname: echoserver-59bf4556cd-xcppv
```

## Test scaling and watch the pod count and host name

```bash
# Scale the deployment up
kubectl scale deploy echoserver --replicas=3

## Result: The client traffic remains pinned to the current pod (i.e. Hostname doesnt change)

# Scale the deployment down
kubectl scale deploy echoserver --replicas=1

## Result: Unless your current pod happens to be the one that remains online, you will see your traffic shift to another pod (i.e. Hostname will change)

# Scale the deployment back up
kubectl scale deploy echoserver --replicas=3

## Result: If you're traffic moved from one backend pod to another, you will see your traffic shift back to the original pod.
```

## What to watch

What you'll see as you run the scale up and down commands, is that the hostname return will be static 