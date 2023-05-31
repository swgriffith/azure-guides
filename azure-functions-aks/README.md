# Running Azure Functions on AKS

## Cluster Creation

```bash
# Set Environment Variables
RG=EphAzFuncAKS
LOC=eastus
CLUSTER_NAME=funcs

# Create Resource Group
az group create -n $RG -l $LOC

# Create Cluster
az aks create -g $RG -n $CLUSTER_NAME --enable-addons azure-policy

# Get Cluster Credentials
az aks get-credentials -g $RG -n $CLUSTER_NAME --admin
```

## Create an Azure Function

```bash
func init --docker --worker-runtime dotnet

func new --name testfunc --language C# --template HttpTrigger --authlevel anonymous

func start

# From another terminal
curl http://localhost:7071/api/testfunc\?name\=steve

# Sample Output
Hello, steve. This HTTP triggered function executed successfully.
```

## Create the Azure Container Registry and Cluster Attach

```bash
# Set ACR Name
ACR_NAME=griffdemo

# Create ACR
az acr create -g $RG -n $ACR_NAME --sku Standard

# Attach ACR to AKS Cluster
az aks update -g $RG -n $CLUSTER_NAME --attach-acr $ACR_NAME
```

## Build and Deploy the Image

```bash
az acr build -r $ACR_NAME -t testfunc  .
```

Create the deployment yaml. Create a new file called testfunc.yaml with the following:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    app: testfunc
  name: testfunc
spec:
  replicas: 1
  selector:
    matchLabels:
      app: testfunc
  template:
    metadata:
      labels:
        app: testfunc
    spec:
      securityContext:
        seccompProfile:
          type: RuntimeDefault
        runAsUser: 1000
        runAsGroup: 3000
        fsGroup: 2000
        supplementalGroups: [4000]
      containers:
      - image: griffdemo.azurecr.io/testfunc:latest
        name: testfunc
        env:
          - name: ASPNETCORE_URLS
            value: http://*:8000
        ports:
        - containerPort: 8000
        securityContext:
          allowPrivilegeEscalation: false
          runAsNonRoot: true
---
apiVersion: v1
kind: Service
metadata:
  name: testfunc-svc
  labels:
    run: testfunc-svc
spec:
  ports:
  - port: 8000
    protocol: TCP
  selector:
    app: testfunc  
  type: LoadBalancer
```

Check the deployment status.

```bash
kubectl get svc,deploy,pods

# Sample Output
NAME                   TYPE           CLUSTER-IP   EXTERNAL-IP     PORT(S)          AGE
service/testfunc-svc   LoadBalancer   10.0.89.41   20.246.233.47   8000:31026/TCP   2m5s

NAME                       READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/testfunc   1/1     1            1           2m5s

NAME                            READY   STATUS    RESTARTS   AGE
pod/testfunc-5f995ccb8d-28x74   1/1     Running   0          2m5s

```

Test the function:

```bash
curl 20.246.233.47:8000/api/testfunc\?name=steve

# Sample Output
Hello, steve. This HTTP triggered function executed successfully.
```
