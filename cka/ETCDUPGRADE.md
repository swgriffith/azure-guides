# etcd Upgrade

In this walk-through, I'll install the etcdctl, take a backup of etcd and restore from the backup.

## Installing etcdctl

```bash
export RELEASE=$(curl -s https://api.github.com/repos/etcd-io/etcd/releases/latest|grep tag_name | cut -d '"' -f 4)
wget https://github.com/etcd-io/etcd/releases/download/${RELEASE}/etcd-${RELEASE}-linux-amd64.tar.gz

tar xvf etcd-${RELEASE}-linux-amd64.tar.gz
cd etcd-${RELEASE}-linux-amd64

sudo mv etcd etcdctl etcdutl /usr/local/bin 

# Check Version
etcdctl version

# Sample output
etcdctl version: 3.5.2
API version: 3.5
```

Get the installed etcd details:

```bash
# Get the pod name
kubectl get pods -n kube-system|grep etcd
etcd-ctrl-node1                      1/1     Running   0              171m

# Describe the pod
kubectl describe pod etcd-ctrl-node1 -n kube-system

# Check out the value for --cert-file, which will tell you your
# local etc cert file locations

# Use the above to build the following command to create a backup
sudo ETCDCTL_API=3 etcdctl --cacert=/etc/kubernetes/pki/etcd/ca.crt \
--cert=/etc/kubernetes/pki/etcd/server.crt \
--key=/etc/kubernetes/pki/etcd/server.key \
snapshot save /opt/etcd-backup.db
```

For fun, lets deploy a pod and then restore the etcd backup.

```bash

# Deploy a pod
kubectl apply -f https://raw.githubusercontent.com/kubernetes/website/main/content/en/examples/pods/simple-pod.yaml

# Check that the pod is running
kubectl get pods -o wide
NAME    READY   STATUS    RESTARTS   AGE     IP          NODE           NOMINATED NODE   READINESS GATES
nginx   1/1     Running   0          2m26s   10.44.0.1   worker-node1   <none>           <none>

# Restore etcd from backup
sudo ETCDCTL_API=3 etcdutl --data-dir=/var/lib/from-backup snapshot restore /opt/etcd-backup.db

# Edit the etcd pod with the new restored data path
cd /etc/kubernetes/manifests/
sudo vim etcd.yaml

# Wait for the pods to come back online. You may need to manually delete the etcd pod
kubectl delete pod etcd-ctrl-node1 -n kube-system

# if the above takes a while you can use the following
kubectl delete pod etcd-ctrl-node1 -n kube-system

# then to speed up reload of all pods in the /etc/kubernetes/manifests folder you can restart kubelet
sudo systemctl restart kubelet
```