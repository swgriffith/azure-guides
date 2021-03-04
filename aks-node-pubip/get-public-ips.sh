#!/bin/bash

# Create a busybox daemonset we can use to callout for the public IPs
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: busybox
  labels:
    app: busybox
spec:
  selector:
    matchLabels:
      app: busybox
  template:
    metadata:
      labels:
        app: busybox
    spec:
      containers:
      - name: busybox
        image: busybox
        args:
        - sleep
        - "10000"
EOF

# Get the public IPs for each node via the daemonset pods
for i in $(kubectl get pods -l app=busybox --output=jsonpath={.items..metadata.name}); do kubectl exec -it $i -- wget -qO- ifconfig.co; done
