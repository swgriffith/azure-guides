# Quck way to test the node exporter metrics

```bash
# Install the test pod to the namespace where you're running prometheus
kubectl apply -f metrics-test-pod.yaml -n monitoring

# exec into the test pod
kubectl exec -it metrics-test-pod -n monitoring -- bash

# From inside the pod, install curl
apt update;apt install -y curl

# Get the token for the service account
token=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)

# Set the target node ip
NODE_IP=10.10.2.5

# Set the metrics port
METRICS_PORT=9100

curl --insecure -H "Accept: application/json" -H "Authorization: Bearer ${token}" https://${NODE_IP}:${METRICS_PORT}/metrics
```