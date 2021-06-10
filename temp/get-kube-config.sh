#!/bin/bash

ssh -o "StrictHostKeyChecking no" $USER@$1 'sudo cp /etc/rancher/k3s/k3s.yaml ~/;sudo chown $USER:$USER k3s.yaml'
mkdir .kube
scp -o "StrictHostKeyChecking no" $USER@$1:~/k3s.yaml ./.kube/config
chmod 744 ~/.kube/config
sed -i 's/127.0.0.1/$1/g' config 

# Wait for cloud-init to finish
while [  $(cat /tmp/cloud-init.status) != 'Ready' ]; do
    echo 'Not Ready'
    sleep 5
done

# Login to Azure with the vm managed identity
az login --identity

