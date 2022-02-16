# Auto-scaling App Using Nginx Ingress Metrics and Prometheus

In this walkthrough we'll set up an AKS cluster running Prometheus and Nginx Ingress, and then show how you can use nginx ingress metrics to autoscale the application.

## Cluster Setup

First lets create the cluster. We'll go with a very basic default config cluster.

```bash
RG=EphHTTPAutoScale
LOC=eastus
CLUSTER_NAME=httpscale

# Create the resource group
az group create -n $RG -l $LOC

# Create the AKS cluster
az aks create -g $RG -n $CLUSTER_NAME 

az aks get-credentials -g $RG -n $CLUSTER_NAME

kubectl create ns httpscaledemo
```

Now to install Prometheus. 

```bash
helm repo add prometheus-community \
    https://prometheus-community.github.io/helm-charts
helm repo update
helm install prometheus prometheus-community/prometheus -n httpscaledemo

# Test Access
# Run the following and then open your browser to http://localhost:8080
kubectl port-forward service/prometheus-server -n httpscaledemo 8080:80

```

Install Keda

```bash
helm repo add kedacore https://kedacore.github.io/charts
helm repo update
helm install keda kedacore/keda --namespace httpscaledemo
```

Install nginx ingress

```bash
helm repo add nginx-stable https://helm.nginx.com/stable
helm repo update

helm install ingress-controller ingress-nginx/ingress-nginx \
--namespace httpscaledemo \
--set controller.metrics.enabled=true \
--set controller.autoscaling.enabled=true \
--set-string controller.podAnnotations."prometheus\.io/scrape"="true" \
--set-string controller.podAnnotations."prometheus\.io/port"="10254"

# Test Metric Scraping
curl 'localhost:8080/api/v1/query?query=nginx_ingress_controller_build_info'
```

Install the sample app

```bash
kubectl apply -f webapp.yaml -n httpscaledemo
kubectl apply -f ingress.yaml -n httpscaledemo

kubectl get svc,pods -n httpscaledemo

# Open your browser and navigate to http://<nginx-ingress public ip>/myapp
```

Deploy the ScaledObject

```bash
kubectl apply -f keda-prom.yml
```

After a few minutes you should see the number of webapp pods drop from 3, which was set in the deployment, to 1 which is the min pods for the scaled object.

Run some load against the site and watch for the pods to scale. I used [hey](https://github.com/rakyll/hey). 

```bash
# In one terminal window
hey -z 5m -c 20 --disable-keepalive http://<Insert you Ingress Public IP>/myapp

# In another terminal window
watch kubectl get pods -n httpscaledemo
```