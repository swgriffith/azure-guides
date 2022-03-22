# Cluster Upgrade

The following steps are used to upgrade your Kubernetes cluster.

```bash

ssh kubeadmin@<controlnodeIP>

# Check the current version
kubectl get nodes
NAME           STATUS   ROLES                  AGE     VERSION
ctrl-node1     Ready    control-plane,master   6m15s   v1.21.11
worker-node1   Ready    <none>                 4m6s    v1.21.11
worker-node2   Ready    <none>                 4m3s    v1.21.11

# Update your package repo
sudo apt update

# Get the current available versions of kubeadm
sudo apt-cache madison kubeadm

kubeadm |  1.23.5-00 | https://apt.kubernetes.io kubernetes-xenial/main amd64 Packages
kubeadm |  1.23.4-00 | https://apt.kubernetes.io kubernetes-xenial/main amd64 Packages
kubeadm |  1.23.3-00 | https://apt.kubernetes.io kubernetes-xenial/main amd64 Packages
kubeadm |  1.23.2-00 | https://apt.kubernetes.io kubernetes-xenial/main amd64 Packages
kubeadm |  1.23.1-00 | https://apt.kubernetes.io kubernetes-xenial/main amd64 Packages
kubeadm |  1.23.0-00 | https://apt.kubernetes.io kubernetes-xenial/main amd64 Packages

# Upgrade kubeadm
sudo apt-mark unhold kubeadm
sudo apt-get update
sudo apt-get install -y kubeadm=1.22.8-00
sudo apt-mark hold kubeadm

# Check for the possible upgrade target versions
sudo kubeadm upgrade plan

# Sample Output
Components that must be upgraded manually after you have upgraded the control plane with 'kubeadm upgrade apply':
COMPONENT   CURRENT        TARGET
kubelet     3 x v1.21.11   v1.22.8

Upgrade to the latest stable version:

COMPONENT                 CURRENT    TARGET
kube-apiserver            v1.21.11   v1.22.8
kube-controller-manager   v1.21.11   v1.22.8
kube-scheduler            v1.21.11   v1.22.8
kube-proxy                v1.21.11   v1.22.8
CoreDNS                   v1.8.0     v1.8.4
etcd                      3.4.13-0   3.5.0-0

You can now apply the upgrade by executing the following command:

	kubeadm upgrade apply v1.22.8
```

Run the kubeadm upgrade:

```bash
sudo kubeadm upgrade apply v1.22.8

# Sample Output
...
[upgrade/successful] SUCCESS! Your cluster was upgraded to "v1.22.8". Enjoy!

[upgrade/kubelet] Now that your control plane is upgraded, please proceed with upgrading your kubelets if you haven't already done so.
...
```

Upgrade Kubelet:

```bash
# Drain the kube-master node (Note: You're master node may have a different name)
kubectl drain ctrl-node1 --ignore-daemonsets

node/ctrl-node1 cordoned
WARNING: ignoring DaemonSet-managed Pods: kube-system/kube-proxy-gnzns, kube-system/weave-net-44wv2
node/ctrl-node1 drained

# Upgrade kubectl and kubelet
sudo apt-mark unhold kubelet kubectl 
sudo apt-get update 
sudo apt-get install -y kubelet=1.22.8-00 kubectl=1.22.8-00
sudo apt-mark hold kubelet kubectl

# Restart kubelet
sudo systemctl daemon-reload
sudo systemctl restart kubelet

# Uncordon the master node
kubectl uncordon ctrl-node1

# Check the master node version
kubectl get nodes
NAME           STATUS   ROLES                  AGE   VERSION
ctrl-node1     Ready    control-plane,master   25m   v1.22.8
worker-node1   Ready    <none>                 23m   v1.21.11
worker-node2   Ready    <none>                 23m   v1.21.11
```

Now we need to run the following steps on each worker node to upgrade. 
*Note:* Using tmux you can [synchronize panes](https://www.hackadda.com/post/2021/3/15/synchronize-panes-in-tmux/) to run commands on both nodes at the same time.

```bash
# Upgrade kubeadm
sudo apt-mark unhold kubeadm
sudo apt-get update
sudo apt-get install -y kubeadm=1.22.8-00
sudo apt-mark hold kubeadm

# Upgrade the node
sudo kubeadm upgrade node

# Sample output
[upgrade] Reading configuration from the cluster...
[upgrade] FYI: You can look at this config file with 'kubectl -n kube-system get cm kubeadm-config -o yaml'
[preflight] Running pre-flight checks
[preflight] Skipping prepull. Not a control plane node.
[upgrade] Skipping phase. Not a control plane node.
[kubelet-start] Writing kubelet configuration to file "/var/lib/kubelet/config.yaml"
[upgrade] The configuration for this node was successfully updated!
[upgrade] Now you should go ahead and upgrade the kubelet package using your package manager.

# Drain the node. Note: This will need to be done from a node where you have the kube config. Mine is on my master node, so I'll run this on that node. I'm also draining both nodes at once, which you may not do in the real world
kubectl drain worker-node1 worker-node2 --ignore-daemonsets

# Install updated kubectl and kubelet versions
sudo apt-mark unhold kubelet kubectl
sudo apt-get update
sudo apt-get install -y kubelet=1.22.8-00 kubectl=1.22.8-00
sudo apt-mark hold kubelet kubectl

# Reload kubelet
sudo systemctl daemon-reload
sudo systemctl restart kubelet

# Uncordon the nodes
kubectl uncordon worker-node1 worker-node2

# Now check to see that all is up and running on kubernetes 1.22.8
kubeadmin@ctrl-node1:~$ kubectl get nodes,pods -o wide -A
NAME                STATUS   ROLES                  AGE    VERSION   INTERNAL-IP   EXTERNAL-IP   OS-IMAGE             KERNEL-VERSION     CONTAINER-RUNTIME
node/ctrl-node1     Ready    control-plane,master   104m   v1.22.8   10.10.8.4     <none>        Ubuntu 18.04.6 LTS   5.4.0-1072-azure   containerd://1.5.5
node/worker-node1   Ready    <none>                 102m   v1.22.8   10.10.8.5     <none>        Ubuntu 18.04.6 LTS   5.4.0-1072-azure   containerd://1.5.5
node/worker-node2   Ready    <none>                 102m   v1.22.8   10.10.8.6     <none>        Ubuntu 18.04.6 LTS   5.4.0-1072-azure   containerd://1.5.5

NAMESPACE     NAME                                     READY   STATUS    RESTARTS       AGE    IP          NODE           NOMINATED NODE   READINESS GATES
kube-system   pod/coredns-78fcd69978-pbhnk             1/1     Running   0              71m    10.32.0.2   ctrl-node1     <none>           <none>
kube-system   pod/coredns-78fcd69978-ph7v7             1/1     Running   0              70m    10.32.0.3   ctrl-node1     <none>           <none>
kube-system   pod/etcd-ctrl-node1                      1/1     Running   0              88m    10.10.8.4   ctrl-node1     <none>           <none>
kube-system   pod/kube-apiserver-ctrl-node1            1/1     Running   0              87m    10.10.8.4   ctrl-node1     <none>           <none>
kube-system   pod/kube-controller-manager-ctrl-node1   1/1     Running   0              87m    10.10.8.4   ctrl-node1     <none>           <none>
kube-system   pod/kube-proxy-fqb79                     1/1     Running   0              86m    10.10.8.5   worker-node1   <none>           <none>
kube-system   pod/kube-proxy-gnzns                     1/1     Running   0              86m    10.10.8.4   ctrl-node1     <none>           <none>
kube-system   pod/kube-proxy-s2kx9                     1/1     Running   0              86m    10.10.8.6   worker-node2   <none>           <none>
kube-system   pod/kube-scheduler-ctrl-node1            1/1     Running   0              87m    10.10.8.4   ctrl-node1     <none>           <none>
kube-system   pod/weave-net-44wv2                      2/2     Running   1 (104m ago)   104m   10.10.8.4   ctrl-node1     <none>           <none>
kube-system   pod/weave-net-dt5wl                      2/2     Running   0              102m   10.10.8.5   worker-node1   <none>           <none>
kube-system   pod/weave-net-m4z79                      2/2     Running   1 (101m ago)   102m   10.10.8.6   worker-node2   <none>           <none>

```



