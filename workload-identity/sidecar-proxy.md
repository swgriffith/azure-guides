# Workload Identity Sidecar Proxy

In some scenarios you may have applications that directly called the Azure Instance Metadata Service to retrieve tokens. While this approach worked with Pod Identity, it is no longer a recommended approach for Workload Identity. However, as you transition from direct IMDS calls to other options, like using the Microsoft Authentication Libraries, you do have the option to use Workload Identity with the sidecar proxy option. This will replicate the behavior of Pod Identity, intercepting the IMDS calls and injecting the client ID of the identity you want to use.

The following walk-through demonstrates the setup.

### Cluster Creation

Create and AKS cluster with the OIDC Issure and Workload Identity add-on enabled.

```bash
RG=WorkloadIdentityRG
LOC=eastus
CLUSTER_NAME=wilab

# Create the resource group
az group create -g $RG -l $LOC

# Create the cluster with the OIDC Issuer and Workload Identity enabled
az aks create -g $RG -n $CLUSTER_NAME \
--node-count 1 \
--enable-oidc-issuer \
--enable-workload-identity \
--generate-ssh-keys

# Get the cluster credentials
az aks get-credentials -g $RG -n $CLUSTER_NAME
```

### Set up the identity 

In order to federate a managed identity with a Kubernetes Service Account we need to get the AKS OIDC Issure URL, create the Managed Identity and Service Account and then create the federation.

```bash
NAMESPACE=kube-system 

# Get the OIDC Issuer URL
export AKS_OIDC_ISSUER="$(az aks show -n $CLUSTER_NAME -g $RG --query "oidcIssuerProfile.issuerUrl" -otsv)"

# Create the managed identity
az identity create --name wi-demo-identity --resource-group $RG --location $LOC

# Get identity client ID
export USER_ASSIGNED_CLIENT_ID=$(az identity show --resource-group $RG --name wi-demo-identity --query 'clientId' -o tsv)

# Create a service account to federate with the managed identity
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: wi-demo-sa
  namespace: ${NAMESPACE}
  annotations:
    azure.workload.identity/client-id: ${USER_ASSIGNED_CLIENT_ID}
  labels:
    azure.workload.identity/use: "true"
EOF

# Federate the identity
az identity federated-credential create \
--name wi-demo-federated-id \
--identity-name wi-demo-identity \
--resource-group $RG \
--issuer ${AKS_OIDC_ISSUER} \
--subject system:serviceaccount:${NAMESPACE}:wi-demo-sa
```

### Deploy a test pod

The following test pod will just run an ubuntu container, but the pod will be created with the following:

* Workload Identity Enabled
* Workload Identity Sidecar Injection Enabled
* Service Account Set

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ubuntu
  namespace: ${NAMESPACE}
  labels:
    azure.workload.identity/use: "true"
  annotations:
    azure.workload.identity/inject-proxy-sidecar: "true"
spec:
  serviceAccountName: wi-demo-sa
  containers:
  - name: ubuntu
    image: ubuntu:20.04
    # Just spin & wait forever
    command: [ "/bin/bash", "-c", "--" ]
    args: [ "apt-get update;apt-get install -y curl;while true; do sleep 30; done;" ]
EOF
```

Now run a test call to the IMDS.

```bash
kubectl exec ubuntu -n $NAMESPACE -- curl -s -H Metadata:true --noproxy "*" "http://169.254.169.254/metadata/identity/oauth2/token?resource=https://management.azure.com/&api-version=2018-02-01"
```

If you take the output access_token value and check it on a site like [jwt.io](https://jwt.io) you should see the token is mapped to the managed identity.

Some data abstracted for security reasons.

```json
{
  "aud": "https://management.azure.com/",
  ...
  "xms_cae": "1",
  "xms_mirid": "/subscriptions/xxx-xxx-xxx-xxx/resourcegroups/WorkloadIdentityRG/providers/Microsoft.ManagedIdentity/userAssignedIdentities/wi-demo-identity",
  "xms_tcdt": 1645137228
}
```

