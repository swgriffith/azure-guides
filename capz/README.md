# CAPZ

## Setup


```bash
RG=EphCAPZ
AZURE_LOCATION=eastus2
CLUSTER_NAME=capz

az group create -n $RG -l $LOC
az aks create -g $RG -n $CLUSTER_NAME
az aks get-credentials -g $RG -n $CLUSTER_NAME

export AZURE_SUBSCRIPTION_ID=$(az account show -o tsv --query id)

# Create an Azure Service Principal and paste the output here
export AZURE_TENANT_ID=$(az account show -o tsv --query tenantId)
az ad sp create-for-rbac --role contributor --scopes="/subscriptions/${AZURE_SUBSCRIPTION_ID}" -o json > cluster-id-sp.json
export AZURE_CLIENT_ID=$(cat cluster-id-sp.json|jq -r .appId)
export AZURE_CLIENT_ID_USER_ASSIGNED_IDENTITY=$AZURE_CLIENT_ID # for compatibility with CAPZ v1.16 templates
export AZURE_CLIENT_SECRET=$(cat cluster-id-sp.json|jq -r .password)



# Settings needed for AzureClusterIdentity used by the AzureCluster
export ASO_CREDENTIAL_SECRET_NAME="cluster-identity-secret"
export CLUSTER_IDENTITY_NAME="cluster-identity"
export AZURE_CLUSTER_IDENTITY_SECRET_NAMESPACE="default"

# Create a secret to include the password of the Service Principal identity created in Azure
# This secret will be referenced by the AzureClusterIdentity used by the AzureCluster
kubectl create secret generic "${AZURE_CLUSTER_IDENTITY_SECRET_NAME}" --from-literal=clientSecret="${AZURE_CLIENT_SECRET}" --namespace "${AZURE_CLUSTER_IDENTITY_SECRET_NAMESPACE}"

cat <<EOF > cluster-identity.yaml
apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
kind: AzureClusterIdentity
metadata:
  labels:
    clusterctl.cluster.x-k8s.io/move-hierarchy: "true"
  name: ${CLUSTER_IDENTITY_NAME}
  namespace: default
spec:
  allowedNamespaces: {}
  clientID: ${AZURE_CLIENT_ID}
  clientSecret:
    name: ${AZURE_CLUSTER_IDENTITY_SECRET_NAME}
    namespace: default
  tenantID: ${AZURE_TENANT_ID}
  type: ServicePrincipal
EOF

# Finally, initialize the management cluster
clusterctl init --infrastructure azure

KUBERNETES_VERSION=1.30.1

cat <<EOF >cluster.yaml
apiVersion: cluster.x-k8s.io/v1beta1
kind: Cluster
metadata:
  name: ${CLUSTER_NAME}
  namespace: default
spec:
  controlPlaneRef:
    apiVersion: infrastructure.cluster.x-k8s.io/v1alpha1
    kind: AzureASOManagedControlPlane
    name: ${CLUSTER_NAME}
  infrastructureRef:
    apiVersion: infrastructure.cluster.x-k8s.io/v1alpha1
    kind: AzureASOManagedCluster
    name: ${CLUSTER_NAME}
---
apiVersion: infrastructure.cluster.x-k8s.io/v1alpha1
kind: AzureASOManagedControlPlane
metadata:
  name: ${CLUSTER_NAME}
  namespace: default
spec:
  resources:
  - apiVersion: containerservice.azure.com/v1api20231001
    kind: ManagedCluster
    metadata:
      annotations:
        serviceoperator.azure.com/credential-from: ${ASO_CREDENTIAL_SECRET_NAME}
      name: ${CLUSTER_NAME}
    spec:
      dnsPrefix: ${CLUSTER_NAME}
      identity:
        type: SystemAssigned
      location: ${AZURE_LOCATION}
      networkProfile:
        networkPlugin: azure
      owner:
        name: ${CLUSTER_NAME}
      servicePrincipalProfile:
        clientId: msi
  version: ${KUBERNETES_VERSION}
---
apiVersion: infrastructure.cluster.x-k8s.io/v1alpha1
kind: AzureASOManagedCluster
metadata:
  name: ${CLUSTER_NAME}
  namespace: default
spec:
  resources:
  - apiVersion: resources.azure.com/v1api20200601
    kind: ResourceGroup
    metadata:
      annotations:
        serviceoperator.azure.com/credential-from: ${ASO_CREDENTIAL_SECRET_NAME}
      name: ${CLUSTER_NAME}
    spec:
      location: ${AZURE_LOCATION}
---
apiVersion: cluster.x-k8s.io/v1beta1
kind: MachinePool
metadata:
  name: ${CLUSTER_NAME}-pool0
  namespace: default
spec:
  clusterName: ${CLUSTER_NAME}
  replicas: ${WORKER_MACHINE_COUNT:=2}
  template:
    metadata: {}
    spec:
      bootstrap:
        dataSecretName: ""
      clusterName: ${CLUSTER_NAME}
      infrastructureRef:
        apiVersion: infrastructure.cluster.x-k8s.io/v1alpha1
        kind: AzureASOManagedMachinePool
        name: ${CLUSTER_NAME}-pool0
      version: ${KUBERNETES_VERSION}
---
apiVersion: infrastructure.cluster.x-k8s.io/v1alpha1
kind: AzureASOManagedMachinePool
metadata:
  name: ${CLUSTER_NAME}-pool0
  namespace: default
spec:
  resources:
  - apiVersion: containerservice.azure.com/v1api20231001
    kind: ManagedClustersAgentPool
    metadata:
      annotations:
        serviceoperator.azure.com/credential-from: ${ASO_CREDENTIAL_SECRET_NAME}
      name: ${CLUSTER_NAME}-pool0
    spec:
      azureName: pool0
      mode: System
      owner:
        name: ${CLUSTER_NAME}
      type: VirtualMachineScaleSets
      vmSize: ${AZURE_NODE_MACHINE_TYPE}
---
apiVersion: cluster.x-k8s.io/v1beta1
kind: MachinePool
metadata:
  name: ${CLUSTER_NAME}-pool1
  namespace: default
spec:
  clusterName: ${CLUSTER_NAME}
  replicas: ${WORKER_MACHINE_COUNT:=2}
  template:
    metadata: {}
    spec:
      bootstrap:
        dataSecretName: ""
      clusterName: ${CLUSTER_NAME}
      infrastructureRef:
        apiVersion: infrastructure.cluster.x-k8s.io/v1alpha1
        kind: AzureASOManagedMachinePool
        name: ${CLUSTER_NAME}-pool1
      version: ${KUBERNETES_VERSION}
---
apiVersion: infrastructure.cluster.x-k8s.io/v1alpha1
kind: AzureASOManagedMachinePool
metadata:
  name: ${CLUSTER_NAME}-pool1
  namespace: default
spec:
  resources:
  - apiVersion: containerservice.azure.com/v1api20231001
    kind: ManagedClustersAgentPool
    metadata:
      annotations:
        serviceoperator.azure.com/credential-from: ${ASO_CREDENTIAL_SECRET_NAME}
      name: ${CLUSTER_NAME}-pool1
    spec:
      azureName: pool1
      mode: User
      owner:
        name: ${CLUSTER_NAME}
      type: VirtualMachineScaleSets
      vmSize: ${AZURE_NODE_MACHINE_TYPE}
EOF
```