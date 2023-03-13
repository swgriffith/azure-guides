# Containerd Upgade Daemonset

The following walks you through the creation of an AKS cluster, manual installation of containerd 1.7, which supports NRI. Then it enables NRI, builds the sample NRI hook examples and sets up the OCI hook-injector.

>*NOTE:* In a real world scenario you would set up a daemonset to configure all of these details across all cluster nodes. The goal of this guide is just to show the basic required steps.

>*WARNING:* As of the writing of this guide, Azure Kubernetes Service is not yet on containerd 1.7. As such, this is not a supported configuration at this time. This document is purely to demonstrate the setup steps.

### Create the cluster
```bash
RG=EphContainerD
LOC=eastus
CLUSTER_NAME=containerd-test

az group create -g $RG -l $LOC

VNET_SUBNET_ID=/subscriptions/286322da-1300-4ce9-a39b-a4b7080f0a94/resourceGroups/networkinfra/providers/Microsoft.Network/virtualNetworks/azure-eastus-vnet/subnets/containerdtest

az aks create -g $RG -n $CLUSTER_NAME --vnet-subnet-id $VNET_SUBNET_ID -c 1

az aks get-credentials -g $RG -n $CLUSTER_NAME --admin
```

### Single node test

```bash
# SSH to the target node
kubectl get nodes -o wide
NAME                                STATUS   ROLES   AGE   VERSION   INTERNAL-IP   EXTERNAL-IP   OS-IMAGE             KERNEL-VERSION     CONTAINER-RUNTIME
aks-nodepool1-17180155-vmss000000   Ready    agent   21m   v1.24.9   10.10.4.4     <none>        Ubuntu 18.04.6 LTS   5.4.0-1103-azure   containerd://1.6.17+azure-1

ssh azureuser@10.10.4.4

cd /tmp

wget https://github.com/containerd/containerd/releases/download/v1.7.0/containerd-1.7.0-linux-amd64.tar.gz
tar xvf containerd-1.7.0-linux-amd64.tar.gz

sudo systemctl stop containerd
# Stop any processes accessing the shim
sudo lsof -t /usr/bin/containerd-shim-runc-v2 | sudo xargs kill
sudo cp bin/containerd* /usr/bin
sudo systemctl start containerd

# In another terminal you can verify the containerd version is updated to 1.7.0
kubectl get nodes -o wide
NAME                                STATUS   ROLES   AGE   VERSION   INTERNAL-IP   EXTERNAL-IP   OS-IMAGE             KERNEL-VERSION     CONTAINER-RUNTIME
aks-nodepool1-17180155-vmss000000   Ready    agent   27m   v1.24.9   10.10.4.4     <none>        Ubuntu 18.04.6 LTS   5.4.0-1103-azure   containerd://1.7.0
```

## Enable NRI and setup the OCI hook-injector

For this test I'll build the OCI Hook-Injector plugin on the AKS node, but you can and should build it externally and then pull it in.

Install go:

```bash
sudo apt update
sudo apt upgrade

# Get Go
wget https://go.dev/dl/go1.20.2.linux-amd64.tar.gz

# Remove old installs and extract the binaries
sudo rm -rf /usr/local/go && sudo tar -C /usr/local -xzf go1.20.2.linux-amd64.tar.gz

# Add go to the path
export PATH=$PATH:/usr/local/go/bin

# Check the go version
go version
go version go1.20.2 linux/amd64
```

Build the OCI hook-injector plugin:

```bash
# Go to azureuser home
cd $HOME 

# Clone the NRI repo
git clone https://github.com/containerd/nri.git

# Build
cd nri
make
```

Enable NRI:

```bash
# Backup your containerd config
sudo cp /etc/containerd/config.toml /tmp

sudo bash -c 'cat << EOF >> /etc/containerd/config.toml
[plugins."io.containerd.nri.v1.nri"]
  # Enable NRI support in containerd.
  disable = false
  # Allow connections from externally launched NRI plugins.
  disable_connections = false
  # plugin_config_path is the directory to search for plugin-specific configuration.
  plugin_config_path = "/etc/nri/conf.d"
  # plugin_path is the directory to search for plugins to launch on startup.
  plugin_path = "/opt/nri/plugins"
  # plugin_registration_timeout is the timeout for a plugin to register after connection.
  plugin_registration_timeout = "5s"
  # plugin_requst_timeout is the timeout for a plugin to handle an event/request.
  plugin_request_timeout = "2s"
  # socket_path is the path of the NRI socket to create for plugins to connect to.
  socket_path = "/var/run/nri/nri.sock"
EOF'
```

Copy the sample hook and hook config to the right paths and then start the hook injector:

```bash
# Get the sample hook script
sudo wget -O /usr/local/sbin/demo-hook.sh https://raw.githubusercontent.com/containerd/nri/main/plugins/hook-injector/usr/local/sbin/demo-hook.sh
sudo chmod +x /usr/local/sbin/demo-hook.sh

# Create the Default Directory used for OCI hooks
sudo mkdir -p /etc/containers/oci/hooks.d
# Get the sample hook config
sudo wget -O /etc/containers/oci/hooks.d/always-inject.json https://raw.githubusercontent.com/containerd/nri/main/plugins/hook-injector/etc/containers/oci/hooks.d/always-inject.json

# Create the plugin directory
sudo mkdir -p /opt/nri/plugins

# Create the symlink to the hook-injector binary
sudo ln -s /home/azureuser/nri/build/bin/hook-injector /opt/nri/plugins/10-hook-injector
```



Deploy a test pod:
```bash
kubectl apply -f https://raw.githubusercontent.com/containerd/nri/main/plugins/hook-injector/sample-hook-inject.yaml

sudo cat /tmp/demo-hook.log

######################################################################
# Sample output
######################################################################
========== [pid 49658] Mon Mar 13 18:07:25 UTC 2023 ==========
command: /usr/local/sbin/demo-hook.sh hook is always injected
environment:
    PWD=/run/containerd/io.containerd.runtime.v2.task/k8s.io/19d00982368f8eb1dbbd02ca0d6085a51490c64af8466318339c59c07d9a5b8a
    DEMO_HOOK_ALWAYS_INJECTED=true
    SHLVL=1
    _=/usr/bin/env
========== [pid 49707] Mon Mar 13 18:07:26 UTC 2023 ==========
command: /usr/local/sbin/demo-hook.sh hook is always injected
environment:
    PWD=/run/containerd/io.containerd.runtime.v2.task/k8s.io/e0e6f4bf87246f1e927ae6d61a187e749fe61cf690aeff889fb697e3f907d92f
    DEMO_HOOK_ALWAYS_INJECTED=true
    SHLVL=1
    _=/usr/bin/env
```

- Created a symlink to the hook-injector binary at /opt/nri/plugins with the name 10-hook-injector
- Added the OCI hook config, using the sample below, at default OCI hook directory: /usr/share/containers/oci/hooks.d
```json
{
    "version": "1.0.0",
    "hook": {
        "path": "/usr/local/sbin/demo-hook.sh",
        "args": ["this", "hook", "is", "always", "injected"],
        "env": [
            "DEMO_HOOK_ALWAYS_INJECTED=true"
        ]
    },
    "when": {
        "always": true
    },
    "stages": ["prestart", "poststop"]
}
```
