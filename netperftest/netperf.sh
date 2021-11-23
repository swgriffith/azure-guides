#!/bin/bash
export SERVERPOOL=nodepool1
export CLIENTPOOL=pool2

# Create iPerf3 Client Jobs
do
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
        args: ['-c',$iperfserver,'-t 120']
      restartPolicy: Never
EOF
done

#!/bin/bash
export SERVERPOOL=pool2
export CLIENTPOOL=nodepool1

# Create iPerf3 Client Jobs
for iperfserver in $(kubectl get pods -l app=iperf3-server-b -o jsonpath='{.items[*].status.podIP}')
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
        args: ['-c',$iperfserver,'-t 120']
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
  echo "-----Logs for: $pod-----"
  kubectl logs $pod
  done
done

# Delete iPerf3 client jobs
for job in $(kubectl get jobs --selector app=iperf-client --output=jsonpath='{.items[*].metadata.name}')
do
  kubectl delete job $job
done