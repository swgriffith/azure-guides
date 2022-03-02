# HPA Test

## Setup

This test was run on an aks cluster running Kubernetes version 1.21.9. No special configuration was applied to the cluster (i.e. default 'az aks create')

The test application is a simple dotnet 6 app build using the functions core tools version 4. You can find the source code and Dockerfile [here](https://github.com/swgriffith/clippyfunc/tree/master/src/clippyfunc6.)

The Kubernetes manifest include the deployment, service (type: LoadBalancer) and the HPA configuration, using autoscaling/v2beta2. 

To install the app:

```bash
kubectl apply -f dotnetappdeployment.yaml
kubectp apply -f dotnet-hpa.yaml
```

Once deployed you can run the following to check the status.

```bash
kubectl get hpa,svc,pods
NAME                                         REFERENCE           TARGETS           MINPODS   MAXPODS   REPLICAS   AGE
horizontalpodautoscaler.autoscaling/clippy   Deployment/clippy   34%/85%, 2%/50%   1         10        1          122m

NAME                 TYPE           CLUSTER-IP    EXTERNAL-IP    PORT(S)        AGE
service/clippy       LoadBalancer   10.0.179.37   40.76.152.45   80:30974/TCP   122m
service/kubernetes   ClusterIP      10.0.0.1      <none>         443/TCP        26h

NAME                          READY   STATUS    RESTARTS   AGE
pod/clippy-865844bb9d-ppsq7   1/1     Running   0          122m
```

You can see the pod utilization before we start the test with the following:

```bash
kubectl top pod --use-protocol-buffers
NAME                      CPU(cores)   MEMORY(bytes)
clippy-865844bb9d-ppsq7   5m           69Mi
```

As you can see, before getting any requests this pod is only using 5m cpu and 69Mi of memory. This aligns with the 'Targets' listed for the HPA of 34%/85% for memory and 2%/50% for cpu. The calculation is as follows, given requested cpu and memory of 200m and 200Mi:

```
---CPU---
Pod 1: 5m/200m=0.025
Avg: (0.025)/1=0.025 (2%)

---Memory---
Pod 1: 69Mi/200Mi=0.345
Avg: (0.345)/1 pod= 0.345 (34%)

---Required Pod Count---
Based on the HPA Algorithm here:
https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/#algorithm-details

ceil[currentReplicas * ( currentMetricValue / desiredMetricValue )] = desiredReplicas

---CPU--- [target 50% from hpa config]
1 * (5m / (50% target * 200m request)) = 0.05
ceil[0.05] = 1 pod required

---Memory--- [target 85% from hpa config]
1 * (69Mi / (85% * 200Mi)) = 0.40
ceil[0.40] = 1 pod required
```

So we can see that our HPA wants us to have one pod and we have one pod. Now lets send some traffic to the pod. For this test I used [hey](https://github.com/rakyll/hey)

First lets have one terminal watching the status of our HPA, one terminal watching the top pod and one for running our test.

Terminal 1:
```bash
watch kubectl get hpa,svc,pods

Every 2.0s: kubectl get hpa,svc,pods                                                                                        snowcrash: Wed Mar  2 15:04:07 2022

NAME                                         REFERENCE           TARGETS           MINPODS   MAXPODS   REPLICAS   AGE
horizontalpodautoscaler.autoscaling/clippy   Deployment/clippy   34%/85%, 2%/50%   1         10        1          137m

NAME                 TYPE           CLUSTER-IP    EXTERNAL-IP    PORT(S)        AGE
service/clippy       LoadBalancer   10.0.179.37   40.76.152.45   80:30974/TCP   137m
service/kubernetes   ClusterIP      10.0.0.1      <none>         443/TCP        27h

NAME                          READY   STATUS    RESTARTS   AGE
pod/clippy-865844bb9d-ppsq7   1/1     Running   0          137m
```

Terminal 2:
```bash
watch kubectl top pod --use-protocol-buffers

Every 2.0s: kubectl top pod --use-protocol-buffers                                                                          snowcrash: Wed Mar  2 15:05:07 2022

NAME                      CPU(cores)   MEMORY(bytes)
clippy-865844bb9d-ppsq7   5m           69Mi
```

Terminal 3:
```bash
# Get the service public IP
SVC_PUB_IP=$(kubectl get svc clippy -o=jsonpath='{.status.loadBalancer.ingress[0].ip}')

# Run the test for 2 minutes
hey -z 2m -m POST -d "test" http://$SVC_PUB_IP/api/clippy
```

In terminal 1 we should eventually see the pods scale up to meet demand.
```bash
NAME                                         REFERENCE           TARGETS            MINPODS   MAXPODS   REPLICAS   AGE
horizontalpodautoscaler.autoscaling/clippy   Deployment/clippy   28%/85%, 83%/50%   1         10        5          142m

NAME                 TYPE           CLUSTER-IP    EXTERNAL-IP    PORT(S)        AGE
service/clippy       LoadBalancer   10.0.179.37   40.76.152.45   80:30974/TCP   142m
service/kubernetes   ClusterIP      10.0.0.1      <none>         443/TCP        27h

NAME                          READY   STATUS    RESTARTS   AGE
pod/clippy-865844bb9d-77p2l   1/1     Running   0          41s
pod/clippy-865844bb9d-ldh2c   1/1     Running   0          56s
pod/clippy-865844bb9d-ppsq7   1/1     Running   0          142m
pod/clippy-865844bb9d-vmttb   1/1     Running   0          71s
pod/clippy-865844bb9d-vxlsb   1/1     Running   0          56s
```

```bash
NAME                      CPU(cores)   MEMORY(bytes)
clippy-865844bb9d-77p2l   4m           52Mi
clippy-865844bb9d-ldh2c   6m           52Mi
clippy-865844bb9d-ppsq7   491m         71Mi
clippy-865844bb9d-vmttb   4m           55Mi
clippy-865844bb9d-vxlsb   5m           53Mi
```

Lets do the math to calculate the required pods based on the above:

```
ceil[currentReplicas * ( currentMetricValue / desiredMetricValue )] = desiredReplicas

---CPU--- [target 50% from hpa config]
1 * (491m / (50% target * 200m request)) = 4.91
ceil[4.91] = 5 pods required...so we scaled up to 5

---Memory--- [target 85% from hpa config]
1 * (71Mi / (85% * 200Mi)) = 0.41
ceil[0.40] = 1 pod required
```

So in the above the CPU metric drove the scale up. This is because our scale target was 85% of our requested 200Mi of memory, or 170Mi. Lets watch our pods scale back down and then we'll try a lower target percentage.

After the 2 minute test we should see our pods scale down one by one at 15 second intervals based on the scale policy.

```bash
NAME                                         REFERENCE           TARGETS           MINPODS   MAXPODS   REPLICAS   AGE
horizontalpodautoscaler.autoscaling/clippy   Deployment/clippy   28%/85%, 2%/50%   1         10        5          143m

NAME                 TYPE           CLUSTER-IP    EXTERNAL-IP    PORT(S)        AGE
service/clippy       LoadBalancer   10.0.179.37   40.76.152.45   80:30974/TCP   143m
service/kubernetes   ClusterIP      10.0.0.1      <none>         443/TCP        27h

NAME                          READY   STATUS        RESTARTS   AGE
pod/clippy-865844bb9d-77p2l   1/1     Terminating   0          114s
pod/clippy-865844bb9d-ldh2c   1/1     Running       0          2m9s
pod/clippy-865844bb9d-ppsq7   1/1     Running       0          143m
pod/clippy-865844bb9d-vmttb   1/1     Running       0          2m24s
pod/clippy-865844bb9d-vxlsb   1/1     Running       0          2m9s

```

Now lets edit the hpa to decrease the memory request 80Mi and see what happens. 80Mi makes more sense given then memory utilization we're seeing seems to be 50-70Mi. Edit the dotnetappdeploy.yaml as follows:

```yaml
        resources:
          limits:
            cpu: 500m
            memory: 300Mi
          requests:
            cpu: 200m
            memory: 80Mi
```

Update the hpa config:

```bash
kubectl apply -f dotnetappdeploy.yaml
deployment.apps/clippy configured
service/clippy unchanged
```

Run the test again: