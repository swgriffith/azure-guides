# Using Helm and Kustomize

This guide will walk through some of the fundamentals of using Helm and Kustomize for parameterized deployment to Kubernetes. 

## Pre-reqs

- Make sure you have access to some Kubernetes cluster (AKS, k3s, etc)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [helm](https://helm.sh/docs/intro/install/)

> Note: The Azure CLI will install kubectl for you, [if you ask it to](https://learn.microsoft.com/en-us/cli/azure/aks?view=azure-cli-latest#az-aks-install-cli), or you can use the [Azure Cloud Shell](https://shell.azure.com) which has both tools installed

## Helm

Lets get started with helm. Helm is an external tool (i.e. not built into Kubernetes itself) originally developed by the team at Deis Labs, and introduced at the first KubeCon. Deis Labs was eventually acquired by Microsoft, bringing a ton of brilliant Kubernetes experts into Microsoft, in particular on our upstream teams.

In the early days of Helm there was a client side and a server side component. THe client side tool was the Helm CLI and the server side was a tool called 'Tiller'. Tiller was problematic, in particular because of the scope of access it needed and the fact that it didnt really havea an On-Behalf-Of call flow capability (i.e. How do you know who actually deployed the solution if Tiller did the actual deployment). As such, Tiller was removed in Helm v3 and now the Helm CLI handles all the manifest rendering and execution against the kubernetes API, which means the user calling helm is the user who's roles apply on the deployment.

The really nice thing about helm is that it operates more like a package manager, like apt, homebrew or chocolaty. Helm charts are part of the OCI specification for container registries, so you can store helm charts in an OCI compliant registry, like [Azure Container Registry](https://learn.microsoft.com/en-us/azure/container-registry/container-registry-helm-repos).


### Using Helm to deploy, update and delete an existing chart

``` bash
# Check your helm version
helm version

# Check what helm repos you have installed
helm repo list

# Add or update a helm repo
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update bitnami

# List the charts in the repo
helm repo list

# Show the version history of a specific chart
helm search repo bitnami/mysql --versions

# Install a specific version of a chart
helm install bitnami/mysql --version 12.3.5 --generate-name

# Take a read through the output. There's usually some important info in there.

# Show the installed helm charts
helm ls

# Check out what was installed. Note that we didnt set the namespace, so it went to default
kubectl get all -n default

# You can also see what helm generated for the install
helm get all <release name>

# Upgrade the chart to a newer version
helm upgrade mysql-1749740824 bitnami/mysql --version 13.0.0

# Quickly watch the upgarde
watch kubectl get all -n default

# Uninstall the installed chart
helm uninstall <release name>
```

Ok...now we've done some basic install, update and delete. Lets show the parameterization side.

```bash
# Lets get the chart package to get the value file
helm fetch bitnami/mysql --untar

# Poke around the directory...pay special attention to the values file

# Install using the CLI to set values directly
# This will make the mysql service a loadbalancer type
helm install bitnami/mysql --generate-name --set primary.service.type="LoadBalancer"

# Get the release name
helm ls

# Change the service type back to ClusterIP
helm upgrade <release name> bitnami/mysql --set primary.service.type="ClusterIP"

# Check the results
kubectl get svc

# Check out the revisions
helm history <release name>

# Roll back
helm rollback <release name> 1

# Check the service again
kubectl get svc

# Check the history again
helm history <release name>

# Uninstall the release
helm uninstall <release name>

# Finally, update the 'primary.service.type' value in the values file and deploy
helm install bitnami/mysql --generate-name --values ./mysql/values.yaml

# Notice that the outcome is the same

# Uninstall the release
helm uninstall <release name>

```

Ok, now that you have a good idea of chart deployment and updates, lets create our own chart.

```bash
# Use helm to scaffold out a new chart
helm create mychart

# Explore the generated chart file
# Check out the _helpers.tpl file under the template

# Edit the chart.yaml to customize the install output
# You can also edit the 'NOTES.txt'

# Now lets install the chart. The syntax changes since the chart is local
# Notice that this time we provide a name for the release 'demochart'
helm install demochart ./mychart --set replicaCount=4 

# Check that the chart was deployed and the replicaCount was set
kubectl get all

# Uninstall the release
helm uninstall demochart
```

## Kustomize

One primary difference with Kustomize, vs Helm, is that Kustomize is part of the upstream Kubernetes project and the kubectl command line itself. 

There are a few special tools included in Kustomize, but lets start with a basic deployment setup. Plenty of examples available [here](https://kubernetes.io/docs/tasks/manage-kubernetes-objects/kustomization/)

```bash
# Make a new directory for the lab
mkdir example
cd example

# Create a deployment.yaml
cat <<EOF >./deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-deployment
  labels:
    app: nginx
spec:
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
      - name: nginx
        image: nginx
EOF

cat <<EOF > namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: whatever
EOF

cat <<EOF >./kustomization.yaml
namespace: my-namespace
namePrefix: dev-
nameSuffix: "-001"
labels:
  - pairs:
      app: bingo
    includeSelectors: true 
commonAnnotations:
  oncallPager: 800-555-1212
resources:
- deployment.yaml
- namespace.yaml
EOF

# Check out the generated output, paying special attention to what you set in the kustomization.yaml
kubectl kustomize ./

# Deploy the customization
kubectl apply -k ./

# Check out the results
kubectl get all -n my-namespace

# Clean up
kubectl delete -k ./
```
