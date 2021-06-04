#!/bin/bash
export SERVERPOOL=nodepool1
export CLIENTPOOL=pool2

#kubectl get nodes -l agentpool=$SERVERPOOL -o jsonpath='{.items[*].status.addresses[?(@.type == "InternalIP")].address}'
#kubectl get pods -l app=iperf3-server -o jsonpath='{.items[*].status.podIP}'

# Create iPerf3 server daemonset
kubectl apply -f iperf3.yaml

# Create iPerf3 Client Jobs
for iperfserver in $(kubectl get pods -l app=iperf3-server -o jsonpath='{.items[*].status.podIP}')
do
cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  labels:
    app: iperf-client
  name: iperf-client-$iperfserver
spec:
  template:
    spec:
      nodeSelector:
        agentpool: $CLIENTPOOL
      containers:
      - name: iperf3-client
        image: networkstatic/iperf3
        args: ['-c',$iperfserver]
      restartPolicy: Never
EOF
done

# Wait for the pods to complete
watch kubectl get pods

# Dump iPer3 Client Logs
for job in $(kubectl get jobs --selector app=iperf-client --output=jsonpath='{.items[*].metadata.name}')
do
  for pod in $(kubectl get pods --selector=job-name=$job --output=jsonpath='{.items[*].metadata.name}')
  do
  kubectl logs $pod
  done
done

# Delete iPerf3 client jobs
for job in $(kubectl get jobs --selector app=iperf-client --output=jsonpath='{.items[*].metadata.name}')
do
  kubectl delete job $job
done