RG=EphAKSKubenetUDR
CLUSTERNAME=kubenetudr
LOCATION=eastus
KEYVAULTNAME=kubenetudrvault
LA_WORKSPACE_NAME=kubenetudrla
WINNODEUSER=azureuser
WINNODEPASSWD='CMONju$stW0rk'

# Delete the old cluster
az aks delete -g $RG -n $CLUSTERNAME -y --no-wait

# Get the subnet id
SUBNET_ID=$(az network vnet show -g $RG -n aksvnet -o tsv --query "subnets[?name=='aks'].id")


# Retrieve the DiskEncryptionSet value and set a variable
diskEncryptionSetId=$(az disk-encryption-set show -n aksDiskEncryptionSetName -g $RG --query id -o tsv)

# Get Workspace ID
LA_WORKSPACE_ID=$(az monitor log-analytics workspace show -g $RG -n $LA_WORKSPACE_NAME -o tsv --query id)

# Recreate the cluster with the additional Windows cluster settings (Azure CNI, Win User and Passwd)
az aks create \
-g $RG \
-n $CLUSTERNAME \
--vnet-subnet-id $SUBNET_ID \
--network-plugin azure \
--node-osdisk-diskencryptionset-id $diskEncryptionSetId \
--enable-aad \
--enable-addons monitoring \
--workspace-resource-id "$LA_WORKSPACE_ID" \
--windows-admin-username azureuser \
--windows-admin-password "$WINNODEPASSWD" \
--vm-set-type VirtualMachineScaleSets \
--node-count 1 \
--outbound-type userDefinedRouting 

# Add the Windows Nodepool
az aks nodepool add \
--resource-group $RG \
--cluster-name $CLUSTERNAME \
--os-type Windows \
--name npwin \
--node-count 1

# Get Cluster Admin Credentials
az aks get-credentials -g $RG -n $CLUSTERNAME --admin

# Add admin role binding for user
cat << EOF | kubectl apply -f -
kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: griff-admin
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: User
  name: "stgriffi@microsoft.com"
EOF

# Get non-admin credential
az aks get-credentials -g $RG -n $CLUSTERNAME


# Deploy the sample app
cat << EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sample
  labels:
    app: sample
spec:
  replicas: 1
  template:
    metadata:
      name: sample
      labels:
        app: sample
    spec:
      nodeSelector:
        "beta.kubernetes.io/os": windows
      containers:
      - name: sample
        image: mcr.microsoft.com/dotnet/framework/samples:aspnetapp
        resources:
          limits:
            cpu: 1
            memory: 800M
          requests:
            cpu: .1
            memory: 300M
        ports:
          - containerPort: 80
  selector:
    matchLabels:
      app: sample
---
apiVersion: v1
kind: Service
metadata:
  name: sample
spec:
  type: LoadBalancer
  ports:
  - protocol: TCP
    port: 80
  selector:
    app: sample
EOF