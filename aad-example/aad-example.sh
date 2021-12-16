
RG=EphAADRBAC
CLUSTER_NAME=aadrbac
LOC=eastus
ADMIN_GROUP_ID=<ADMIN AAD GROUP OBJECT ID>
TEAM_A_GROUP_ID=<TEAM A AAD GROUP OBJECT ID>
TEAM_B_GROUP_ID=<TEAM A AAD GROUP OBJECT ID>
AAD_TENANT_ID=<AAD TENANT ID>

az group create -n $RG -l $LOC
az aks create -g $RG -n $CLUSTER_NAME \
--enable-aad \
--enable-azure-rbac \
--disable-local-accounts \
--enable-managed-identity \
--aad-admin-group-object-ids $ADMIN_GROUP_ID \
--aad-tenant-id $AAD_TENANT_ID 

# Try to get the admin cred....this will fail because we disabled local accounts
az aks get-credentials -g $RG -n $CLUSTER_NAME --admin

az aks get-credentials -g $RG -n $CLUSTER_NAME
# Login with user which has full admin rights via the demo-cluster-admins group

# Create sample workloads
kubectl create ns team-a
kubectl create ns team-b

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  labels:
    run: team-a-app
  name: team-a-app
  namespace: team-a
spec:
  containers:
  - image: ubuntu
    name: ubuntu
    command: [ "/bin/bash", "-c", "--" ]
    args: [ "while true; do sleep 30; done;" ]
  restartPolicy: Never
EOF

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  labels:
    run: team-b-app
  name: team-b-app
  namespace: team-b
spec:
  containers:
  - image: ubuntu
    name: ubuntu
    command: [ "/bin/bash", "-c", "--" ]
    args: [ "while true; do sleep 30; done;" ]
  restartPolicy: Never
EOF

# Get your AKS Resource ID
AKS_ID=$(az aks show -g $RG -n $CLUSTER_NAME --query id -o tsv)

# Create role assignments
az role assignment create --role "Azure Kubernetes Service RBAC Reader" --assignee-object-id $TEAM_A_GROUP_ID --scope $AKS_ID/namespaces/team-a
az role assignment create --role "Azure Kubernetes Service RBAC Reader" --assignee-object-id $TEAM_B_GROUP_ID --scope $AKS_ID/namespaces/team-b

# Remove the kube config and login as a member of the team a group
rm ~/.kube/config
az aks get-credentials -g $RG -n $CLUSTER_NAME

# Try to get pods from the default namespace. This will fail.
kubectl get pods

# Get pods from the team-a namespace. This will work.
kubectl get pods -n team-a

# Remove the kube config and login as a member of the team b group
rm ~/.kube/config
az aks get-credentials -g $RG -n $CLUSTER_NAME

# Try to get pods from the default namespace. This will fail.
kubectl get pods

# Get pods from the team-b namespace. This will work.
kubectl get pods -n team-b


