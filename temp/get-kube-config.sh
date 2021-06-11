#!/bin/bash
#CONTROL_HOST=$1
ssh -o "StrictHostKeyChecking no" $USER@$CONTROL_HOST 'sudo cp /etc/rancher/k3s/k3s.yaml ~/;sudo chown $USER:$USER k3s.yaml'
mkdir .kube
scp -o "StrictHostKeyChecking no" $USER@$CONTROL_HOST:~/k3s.yaml ./.kube/config
chmod 744 ~/.kube/config
sed -i 's/127.0.0.1/'$CONTROL_HOST'/g' ./.kube/config 

# Wait for cloud-init to finish
while [ ! -f /tmp/cloud-init-done ]; do echo 'Not Ready';sleep 5; done

# Login to Azure with the vm managed identity
az login --identity
az extension add --name connectedk8s
