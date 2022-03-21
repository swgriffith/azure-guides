# Cluster Creation

These are my quick notes for CKA prep. 

### Provision Infrastructure (Azure)

Provisioning in Azure and using my default local .ssh profile. You may need to adjust the commands below if you which to use something other than ~/.ssh/id_rsa.pub (ex. password auth). I'm also using an existing Vnet/Subnet that is connected to my home S2S VPN (i.e. no need for public IPs), so you should modify the below to match your prefered infra setup.

```bash
RG=EphCKAInfra
LOC=eastus
VNET_NAME=azure-eastus-vnet
SUBNET_ID=/subscriptions/<subscription ID>/resourceGroups/networkinfra/providers/Microsoft.Network/virtualNetworks/azure-eastus-vnet/subnets/cka
VNET_RG=networkinfra

# Create the resource group
az group create -n $RG -l $LOC

az network nsg create \
--resource-group $RG \
--name kubeadm

az network nsg rule create \
--resource-group $RG \
--nsg-name kubeadm \
--name kubeadmssh \
--protocol tcp \
--priority 1000 \
--destination-port-range 22 \
--access allow

az network nsg rule create \
--resource-group $RG \
--nsg-name kubeadm \
--name kubeadmWeb \
--protocol tcp \
--priority 1001 \
--destination-port-range 6443 \
--access allow

az vm create \
--resource-group $RG \
--name ctrl-node1 \
--image UbuntuLTS \
--size Standard_D3_v2 \
--admin-username kubeadmin \
--public-ip-address "" \
--nsg kubeadm \
--subnet $SUBNET_ID

az vm create \
--resource-group $RG \
--name worker-node1 \
--image UbuntuLTS \
--size Standard_D3_v2 \
--admin-username kubeadmin \
--public-ip-address "" \
--nsg kubeadm \
--subnet $SUBNET_ID

az vm create \
--resource-group $RG \
--name worker-node2 \
--image UbuntuLTS \
--size Standard_D3_v2 \
--admin-username kubeadmin \
--public-ip-address "" \
--nsg kubeadm \
--subnet $SUBNET_ID

```

### Install Kubernetes

This is based on the upstream docs, as well as [this guide](https://blog.nillsf.com/index.php/2021/10/29/setting-up-kubernetes-on-azure-using-kubeadm/) from [Nills Franssens](https://twitter.com/NillsF).

```bash
######################################################################
# Install pre-reqs
# These steps will probably already be done for you, but you can get them
# from the kubeadm setup guide here:
# https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/
######################################################################
ssh kubeadmin@<ctrl-ipaddr>

sudo apt update
sudo apt -y install curl apt-transport-https;

curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -
echo "deb https://apt.kubernetes.io/ kubernetes-xenial main" | sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt update
sudo apt -y install vim git curl wget kubelet kubeadm kubectl containerd;

sudo apt-mark hold kubelet kubeadm kubectl containerd

kubectl version --client && kubeadm version

cat <<EOF | sudo tee /etc/modules-load.d/containerd.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

# Setup required sysctl params, these persist across reboots.
cat <<EOF | sudo tee /etc/sysctl.d/99-kubernetes-cri.conf
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF

# Apply sysctl params without reboot
sudo sysctl --system

sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml

sudo systemctl restart containerd

cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
br_netfilter
EOF

cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
EOF
sudo sysctl --system
######################################################################
######################################################################

# Install Kubernetes (Save off the output for later use)
sudo kubeadm init --pod-network-cidr 10.233.0.0/16 \
--apiserver-advertise-address 10.10.8.4

######################################################################
# Sample Output
######################################################################
Your Kubernetes control-plane has initialized successfully!

To start using your cluster, you need to run the following as a regular user:

  mkdir -p $HOME/.kube
  sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
  sudo chown $(id -u):$(id -g) $HOME/.kube/config

Alternatively, if you are the root user, you can run:

  export KUBECONFIG=/etc/kubernetes/admin.conf

You should now deploy a pod network to the cluster.
Run "kubectl apply -f [podnetwork].yaml" with one of the options listed at:
  https://kubernetes.io/docs/concepts/cluster-administration/addons/

Then you can join any number of worker nodes by running the following on each as root:

kubeadm join 10.10.8.4:6443 --token 53...sm.nj0.....gt3kmm7 \
	--discovery-token-ca-cert-hash sha256:717af2199aa5ed08249afee........8adc56f08611af8
######################################################################
```

```bash
# Run the commands to move and chown the kube config file
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# Install a CNI 
kubectl apply -f "https://cloud.weave.works/k8s/net?k8s-version=$(kubectl version | base64 | tr -d '\n')"

kubectl get nodes

NAME         STATUS   ROLES                  AGE   VERSION
ctrl-node1   Ready    control-plane,master   12m   v1.23.5
```

Now to set up the worker nodes. We'll SSH to each and run the same commands above, up until the kubeadm command, which we will instead use the command generated by the output of the control plane node creation.

```bash
sudo kubeadm join 10.10.8.4:6443 --token 53jjsm.nj0gt3kmm7 --discovery-token-ca-cert-hash sha256:717af2199c0105a6156b489588adc56f08611af8
[preflight] Running pre-flight checks
[preflight] Reading configuration from the cluster...
[preflight] FYI: You can look at this config file with 'kubectl -n kube-system get cm kubeadm-config -o yaml'
W0321 21:07:47.079740   20298 utils.go:69] The recommended value for "resolvConf" in "KubeletConfiguration" is: /run/systemd/resolve/resolv.conf; the provided value is: /run/systemd/resolve/resolv.conf
[kubelet-start] Writing kubelet configuration to file "/var/lib/kubelet/config.yaml"
[kubelet-start] Writing kubelet environment file with flags to file "/var/lib/kubelet/kubeadm-flags.env"
[kubelet-start] Starting the kubelet
[kubelet-start] Waiting for the kubelet to perform the TLS Bootstrap...

This node has joined the cluster:
* Certificate signing request was sent to apiserver and a response was received.
* The Kubelet was informed of the new secure connection details.

Run 'kubectl get nodes' on the control-plane to see this node join the cluster.
```

We should now have a running cluster!

```bash
kubeadmin@ctrl-node1:~$ kubectl get nodes,svc,pods -A -o wide
NAME                STATUS   ROLES                  AGE   VERSION   INTERNAL-IP   EXTERNAL-IP   OS-IMAGE             KERNEL-VERSION     CONTAINER-RUNTIME
node/ctrl-node1     Ready    control-plane,master   96m   v1.23.5   10.10.8.4     <none>        Ubuntu 18.04.6 LTS   5.4.0-1072-azure   containerd://1.5.5
node/worker-node1   Ready    <none>                 19m   v1.23.5   10.10.8.5     <none>        Ubuntu 18.04.6 LTS   5.4.0-1072-azure   containerd://1.5.5
node/worker-node2   Ready    <none>                 16m   v1.23.5   10.10.8.6     <none>        Ubuntu 18.04.6 LTS   5.4.0-1072-azure   containerd://1.5.5

NAMESPACE     NAME                 TYPE        CLUSTER-IP   EXTERNAL-IP   PORT(S)                  AGE   SELECTOR
default       service/kubernetes   ClusterIP   10.96.0.1    <none>        443/TCP                  96m   <none>
kube-system   service/kube-dns     ClusterIP   10.96.0.10   <none>        53/UDP,53/TCP,9153/TCP   96m   k8s-app=kube-dns

NAMESPACE     NAME                                     READY   STATUS    RESTARTS      AGE   IP          NODE           NOMINATED NODE   READINESS GATES
kube-system   pod/coredns-64897985d-sh9fr              1/1     Running   0             96m   10.32.0.3   ctrl-node1     <none>           <none>
kube-system   pod/coredns-64897985d-x28wf              1/1     Running   0             96m   10.32.0.2   ctrl-node1     <none>           <none>
kube-system   pod/etcd-ctrl-node1                      1/1     Running   0             96m   10.10.8.4   ctrl-node1     <none>           <none>
kube-system   pod/kube-apiserver-ctrl-node1            1/1     Running   0             96m   10.10.8.4   ctrl-node1     <none>           <none>
kube-system   pod/kube-controller-manager-ctrl-node1   1/1     Running   0             96m   10.10.8.4   ctrl-node1     <none>           <none>
kube-system   pod/kube-proxy-lm972                     1/1     Running   0             96m   10.10.8.4   ctrl-node1     <none>           <none>
kube-system   pod/kube-proxy-npqtn                     1/1     Running   0             19m   10.10.8.5   worker-node1   <none>           <none>
kube-system   pod/kube-proxy-xbs5r                     1/1     Running   0             16m   10.10.8.6   worker-node2   <none>           <none>
kube-system   pod/kube-scheduler-ctrl-node1            1/1     Running   0             96m   10.10.8.4   ctrl-node1     <none>           <none>
kube-system   pod/weave-net-57mfs                      2/2     Running   1 (87m ago)   87m   10.10.8.4   ctrl-node1     <none>           <none>
kube-system   pod/weave-net-hv2x5                      2/2     Running   0             19m   10.10.8.5   worker-node1   <none>           <none>
kube-system   pod/weave-net-qhsxk                      2/2     Running   0             16m   10.10.8.6   worker-node2   <none>           <none>
```
