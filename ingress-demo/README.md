# Sample Ingress

```bash
# Create the sample namespace
kubectl create ns ingress-demo

# Create the app deployment and service
kubectl apply -f webapp.yaml -n ingress-demo

# Check Status
kubectl get svc,pods -n ingress-demo
NAME                 TYPE        CLUSTER-IP       EXTERNAL-IP   PORT(S)   AGE
service/webapp-svc   ClusterIP   10.200.236.142   <none>        80/TCP    11s

NAME                          READY   STATUS    RESTARTS   AGE
pod/webapp-65c58bf797-5jx5j   1/1     Running   0          11s
pod/webapp-65c58bf797-knlkj   1/1     Running   0          11s
pod/webapp-65c58bf797-lkw8t   1/1     Running   0          11s
```

Now install the ingress controller. Note that I installed it in it's the same namespace as my app. It is possible to have one ingress controller used across many namespaces, but you should check the docs for the specific ingress controller for the details.

```bash
# Install Ingress Controller
helm install nginx-ingress ingress-nginx/ingress-nginx \
    --namespace ingress-demo \
    --set controller.replicaCount=2 \
    --set controller.nodeSelector."beta\.kubernetes\.io/os"=linux \
    --set defaultBackend.nodeSelector."beta\.kubernetes\.io/os"=linux 
```

Now we create the ingress object that links the ingress controller to the backend service.

```bash
# Create the ingress route
kubectl apply -f ingress.yaml -n ingress-demo

# Get the ingress IP
ubectl get ingress -n ingress-demo
NAME             HOSTS   ADDRESS      PORTS   AGE
webapp-ingress   *       20.185.9.2   80      24m

# Curl the endpoint
curl http://20.185.9.2/myapp
```