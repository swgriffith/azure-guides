# AKS Kubernetes RBAC Walkthrough

## Introduction

In this walk through we'll create an AKS cluster with Entra ID authentication enabled and demonstrate using Kubernetes Role Based Access Control for both admin and individual user access.

>*NOTE:* [Kubelogin](https://azure.github.io/kubelogin/index.html) is now required to use Entra ID integrated authentication, since cloud provider specific code has been removed from kubectl upstream. You can find the install steps [here](https://azure.github.io/kubelogin/install.html)

### Cluster Setup

In this cluster we will enable managed Entra ID Integrated Auth, disable local accounts and set an Admin Group ID.

```bash
# Set Env Vars
RG=EphEntraIDAKSLab
LOC=eastus
CLUSTER_NAME=entraidlab
ADMIN_GROUP_ID=<Admin Group ID>

# Create the resource group
az group create -n $RG -l $LOC

# Create the cluster
az aks create \
-g $RG \
-n $CLUSTER_NAME \
--enable-aad \
--disable-local-accounts \
--aad-admin-group-object-ids $ADMIN_GROUP_ID \
-c 1

# Get the cluster ID for later
AKS_ID=$(az aks show -g $RG -n $CLUSTER_NAME --query id -o tsv)
```

### Login as Admin

When you disable local accounts, as we did in the command above, you are required to provide one to many admin group IDs. You should be sure your identity is part of that admin group before running the next set of commands.

When you want to access a cluster via kubectl you will need to get the credential file. In an Entra ID enabled cluster, this file is really just the certificates used to access the API server securely. The rest of the credentials will be pulled via kubelogin when you try to access the cluster and are forced to authenticate.

```bash
# Get the kubeconfig file
az aks get-credentials -g $RG -n $CLUSTER_NAME

# Try to get pods
kubectl get pods -A
```

After the above command you should be prompted to run through your Entra ID Auth process and, once authenticated, you should see the list of pods in the cluster.

Before we move on, lets create some resources for our user to try to access in the next step.

```bash
# Create a namespace
kubectl create ns testns

# Create a configmap
kubectl create configmap my-config --from-literal=key1=config1 -n testns

# Create a secret
kubectl create secret generic db-user-pass \
    --from-literal=username=admin \
    --from-literal=password='testpasswd' \
    -n testns

# Create a deployment
kubectl create deployment test --image=nginx -n testns

# Create a service
kubectl expose deployment test --type=LoadBalancer --port=8080 -n testns
```

### Set up the test user

For this demo, we will create a service account to access the cluster. We'll add this service account to an Entra ID cluster users group and then we'll log in as that user. 

```bash
# Create a service principal
az ad sp create-for-rbac --skip-assignment -o json> clustersp.json

# Set some variables for the service principal ID and password 
SP_ID=$(cat clustersp.json|jq -r .appId)
SP_OBJ_ID=$(az ad sp show --id $SP_ID --query id -o tsv)
SP_PASS=$(cat clustersp.json|jq -r .password)
TENANT_ID=$(cat clustersp.json|jq -r .tenant)

# Give the service principal rights to get the kubeconfig file
az role assignment create --assignee $SP_ID --role "Azure Kubernetes Service Cluster User Role" --scope $AKS_ID

# Create a 'test-reader' group
az ad group create --display-name devteam-reader --mail-nickname devteam-reader

# Get the group ID for later use
USER_GROUP_ID=$(az ad group show -g devteam-reader -o tsv --query id)

# Add the service principal to the group
az ad group member add --group $USER_GROUP_ID --member-id $SP_OBJ_ID
```

After setting up the service principal, you need to go to the portal and add the servivce principal to your user group. Get the Group ID for that user group for use below.

### Create the Kubernetes Role and Role Binding

While still logged in as the administrator, lets create the Kubernetes Role and Role binding.

```bash
# Create a pod reader role
kubectl create role pod-reader --verb=get --verb=list --verb=watch --resource=pods -n testns

# Create the pod reader role binding for our Namespace and User Group
cat << EOF > rolebinding.yaml
kind: RoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: pod-reader-binding
  namespace: testns
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: pod-reader
subjects:
- kind: Group
  namespace: testns
  name: $USER_GROUP_ID
EOF

# Apply the rolebinding
kubectl apply -f rolebinding.yaml
```

### Login as the service principal user

Now lets login as the service principal user.

```bash
# Login in with the service principal
az login --service-principal -u $SP_ID -p $SP_PASS --tenant $TENANT_ID

# Get the cluster credentials
az aks get-credentials -g $RG -n $CLUSTER_NAME
```

Since we're using a service principal login, we need to conver the kube config file to a service principal configuration. You would not need to do this next step if you were logging in as a standard Entra ID user.

```bash
# Convert the kube config file for service principal login
kubelogin convert-kubeconfig -l spn
```

Now we can check our access.

```bash
# The following should all fail because we dont have cluster level resource access (i.e. nodes)
kubectl get nodes
kubectl cluster-info

# The following should fail because we dont have access to these namespaces
kubectl get all -n default
kubectl get all -n kube-system

# Getting Pods for the testns should work
kubectl get pods -n testns

# Getting anything else from the testns should not work
kubectl get configmaps -n testns
kubectl get secrets -n testns
kubectl get deployments -n testns
kubectl get svc -n testns
kubectl get serviceaccounts -n testns

# You also cannot edit resource
kubectl run test --image=nginx
```

You can also play around with the [kubectl auth can-i]() to check your access.

```bash
# Examples
kubectl auth can-i create pods -n default
kubectl auth can-i create pods -n testns
kubectl auth can-i get pods -n testns

kubectl auth can-i --list -n default
kubectl auth can-i --list -n testns

```

## Conclusion

You should now have a working Entra ID enabled cluster that uses Kubernetes native RBAC. You also have both an Admin User with full cluster access and a normal user with access only to read pods in a specific namespace.




