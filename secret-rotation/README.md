# AKS and the Key Vault CSI Driver

In this walkthrough we'll set up a cluster with Azure Workload Identity enabled as well as the Azure Key Vault Secret Provider CSI Driver. We'll show an example of how you can load values from a key vault secret into a running pod and then the process for updating those secrets and reloading the values in the pod.

## Cluster Setup

First we'll create the AKS cluser with Workload Identity and the Key Vault CSI driver enabled. Workload Identity also requires you enable the OIDC Issuer option on the cluster.

```bash
RG=EphKVCSI
LOC=eastus
KV_NAME=griffdemokv
CLUSTER_NAME=kvcsidemo
ACR_NAME=griffkvdemoacr

az group create -n $RG -l $LOC

# Create the ACR
az acr create -g $RG -n $ACR_NAME --sku Standard

# Create the cluster with the OIDC Issuer and Workload Identity enabled
az aks create -g $RG -n $CLUSTER_NAME \
--node-count 1 \
--enable-oidc-issuer \
--enable-workload-identity \
--enable-addons azure-keyvault-secrets-provider \
--generate-ssh-keys

# Get the cluster credentials
az aks get-credentials -g $RG -n $CLUSTER_NAME
```

### Set up the identity 

In order to federate a managed identity with a Kubernetes Service Account we need to get the AKS OIDC Issure URL, create the Managed Identity and Service Account and then create the federation.

```bash
# Get the OIDC Issuer URL
export AKS_OIDC_ISSUER="$(az aks show -n $CLUSTER_NAME -g $RG --query "oidcIssuerProfile.issuerUrl" -otsv)"

# Create the managed identity
az identity create --name kvcsi-demo-identity --resource-group $RG --location $LOC

# Get identity client ID
export USER_ASSIGNED_CLIENT_ID=$(az identity show --resource-group $RG --name kvcsi-demo-identity --query 'clientId' -o tsv)

# Get the identity tenant ID
export IDENTITY_TENANT=$(az aks show --name $CLUSTER_NAME --resource-group $RG --query identity.tenantId -o tsv)

# Create a service account to federate with the managed identity
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  annotations:
    azure.workload.identity/client-id: ${USER_ASSIGNED_CLIENT_ID}
  labels:
    azure.workload.identity/use: "true"
  name: kvcsi-demo-sa
  namespace: default
EOF

# Federate the identity
az identity federated-credential create \
--name kvcsi-demo-federated-id \
--identity-name kvcsi-demo-identity \
--resource-group $RG \
--issuer ${AKS_OIDC_ISSUER} \
--subject system:serviceaccount:default:kvcsi-demo-sa
```

## Key Vault Setup

Next, we can create the Key Vault and the secret. We'll authorize the federated managed identity that we created above to 'get' the secret.

```bash
# Create a key vault
az keyvault create --name $KV_NAME --resource-group $RG --location $LOC

# Create a secret
az keyvault secret set --vault-name $KV_NAME --name "Secret" --value "Hello From Key Vault CSI"

# Grant access to the secret for the managed identity
az keyvault set-policy --name $KV_NAME --secret-permissions get --spn "${USER_ASSIGNED_CLIENT_ID}"
```

Now that we have the cluster and the secret, we can use the Key Vault CSI driver's SecretProviderClass to create the clusters representation of the remote secret in Azure Key Vault. In the SecretProviderClass we'll also use the 'secretObject' section to automatically create a Kubernetes secret object when this SecretProviderClass is used.

## Create the Secret Provider Class
```bash
cat <<EOF | kubectl apply -f -
# This is a SecretProviderClass example using workload identity to access your key vault
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: azure-kvname-wi # needs to be unique per namespace
spec:
  provider: azure
  parameters:
    usePodIdentity: "false"
    clientID: "${USER_ASSIGNED_CLIENT_ID}" # Setting this to use workload identity
    keyvaultName: ${KV_NAME}       # Set to the name of your key vault
    cloudName: ""                         # [OPTIONAL for Azure] if not provided, the Azure environment defaults to AzurePublicCloud
    objects:  |
      array:
        - |
          objectName: Secret             # Set to the name of your secret
          objectType: secret              # object types: secret, key, or cert
    tenantId: "${IDENTITY_TENANT}"        # The tenant ID of the key vault
  secretObjects:                              # [OPTIONAL] SecretObjects defines the desired state of synced Kubernetes secret objects
  - data:
    - key: mysecret                           # data field to populate
      objectName: Secret                        # name of the mounted content to sync; this could be the object name or the object alias
    secretName: syncedsecret                     # name of the Kubernetes secret object
    type: Opaque   
EOF
```

## Create a test pod

Now, lets create a simple test pod to mount the secret as a volume via the Key Vault CSI Driver, and then also mount the value in the generated Kubernetes secret into an environment variable. Then we'll test that all the values are loaded.

```bash
cat <<EOF | kubectl apply -f -
# This is a sample deployment definition for using SecretProviderClass and workload identity to access your key vault
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kv-csi-demo
  labels:
    run: kv-csi-demo
spec:
  replicas: 1
  selector:
    matchLabels:
      run: kv-csi-demo
  template:
    metadata:
      name: kv-csi-demo-pod
      labels:
        run: kv-csi-demo
        azure.workload.identity/use: "true"
    spec:
      serviceAccountName: "kvcsi-demo-sa"
      containers:
      - name: busybox
        image: registry.k8s.io/e2e-test-images/busybox:1.29-4
        command:
        - "/bin/sleep"
        - "10000"
        volumeMounts:
        - name: secrets-store01-inline
          mountPath: "/mnt/secrets-store"
          readOnly: true
        env:
        - name: SYNCED_SECRET
          valueFrom:
            secretKeyRef:
              name: syncedsecret
              key: mysecret
      volumes:
      - name: secrets-store01-inline
        csi:
          driver: secrets-store.csi.k8s.io
          readOnly: true
          volumeAttributes:
            secretProviderClass: "azure-kvname-wi"
EOF

# Check that the secret was created and connected to the pod env var
kubectl get secret syncedsecret -o jsonpath='{.data.mysecret}'|base64 --decode

# Get the pod name
POD_NAME=$(kubectl get pods -o jsonpath='{.items[0].metadata.name}')

# Check the environment variable
kubectl exec -it $POD_NAME -- /bin/sh -c 'echo $SYNCED_SECRET'

# Exec into the running pod
kubectl exec -it $POD_NAME -- /bin/sh -c 'cat /mnt/secrets-store/Secret'
```

## Test Secret Update

Secrets do need to be updated from time to time. There are several strategies to manage this update. Since Key Vault Secrets have a version ID, you can add a new version and then update the secret provider class with the new version. You could do the same if you were using the SDK directly from your application without the CSI driver. You can also just update the secret value directly, without the provider class knowing the version number, and let the value automatically sync. The approach you take will depend on the secret rotation behavior that works best for your application. Regardless, however, you will still likely need to reload your application and your deployment to get the updated secret.

Let's check the default behavior when you update a secret value. We'll update the secret and then watch the cluster and deployment behavior.

```bash
# Update the secret value
az keyvault secret set --vault-name $KV_NAME --name "Secret" --value "Updated Secret"

# Watch the secret to see if it changes (wait 3-4 min)
watch 'kubectl get secret syncedsecret -o jsonpath='{.data.mysecret}'|base64 --decode'
```

After a few minutes, you'll notice that the secret value has not been automatically updated. That's because the Key Vault CSI driver does not automatically run secret rotation. You need to enable auto-rotation and optionally provide a rotation interval. Lets enable rotation with a 1 minute interval and then check the behavior.

```bash
# Update the add-on to enable rotation
az aks addon update -g $RG -n $CLUSTER_NAME -a azure-keyvault-secrets-provider --enable-secret-rotation --rotation-poll-interval 1m

# Now watch the secret again and you will see it update automatically
watch 'kubectl get secret syncedsecret -o jsonpath='{.data.mysecret}'|base64 --decode'
```

You should have seen the secret value automatically rotate. You can keep running secret updates and watch the result. 

Now lets check the status of the secrets in the pod.

```bash
# Check the environment variable
# You will see that it has not update
kubectl exec -it $POD_NAME -- /bin/sh -c 'echo $SYNCED_SECRET'

# Check the volume mount
# This has been updated
kubectl exec -it $POD_NAME -- /bin/sh -c 'cat /mnt/secrets-store/Secret'

```

So, while the mounted volume got the updated secret value, the environment variable did not. For that environment variable to reload something has to be watching the secret and tell it to reload. You'll likely see the same behavior within your running application. If you've loaded a secret into memory and the value is updated, even within the pod iteself, the application will need to load the new value into the active process.

There are several ways to handle this as well. Most commonly, you would have a CI/CD pipeline tied to the secret update and that process would trigger a reload of the deployment, either by updating a value in the deployment, like a secret version number, or by directly triggering a deployment restart (kubectl rollout restart deployment). 

## Reloading values in deployments

First lets update the deployment directly via a rollout restart.

```bash
# Trigger a rollout restart
kubectl rollout restart deployment/kv-csi-demo

# Get the pod name and check the secret values again
# Get the pod name
POD_NAME=$(kubectl get pods -o jsonpath='{.items[0].metadata.name}')

# Check the environment variable
kubectl exec -it $POD_NAME -- /bin/sh -c 'echo $SYNCED_SECRET'

# Exec into the running pod
kubectl exec -it $POD_NAME -- /bin/sh -c 'cat /mnt/secrets-store/Secret'
```

You should now see both the environment variable and the mounted volume have been updated. You can repeat the process of updating the secret in Key Vault and then running the rollout restart to test further.

If, however, you want to automatically update the deployment when a secret change event occurs, there are solution for that as well. Lets test with [Reloader](https://github.com/stakater/Reloader). 

We'll install Reloader, delete the deployment and then redeploy with the Reloader annotation for our secret.

```bash
# Install Reloader
kubectl apply -f https://raw.githubusercontent.com/stakater/Reloader/master/deployments/kubernetes/reloader.yaml

# Delete the old deployment. Alternatively you could patch it.
kubectl delete deployment kv-csi-demo

# Add the secret reloader annotation for our secret
# secret.reloader.stakater.com/reload: "syncedsecret"
cat <<EOF | kubectl apply -f -
# This is a sample deployment definition for using SecretProviderClass and workload identity to access your key vault
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kv-csi-demo
  annotations:
    secret.reloader.stakater.com/reload: "syncedsecret"
  labels:
    run: kv-csi-demo
spec:
  replicas: 1
  selector:
    matchLabels:
      run: kv-csi-demo
  template:
    metadata:
      name: kv-csi-demo-pod
      labels:
        run: kv-csi-demo
        azure.workload.identity/use: "true"
    spec:
      serviceAccountName: "kvcsi-demo-sa"
      containers:
      - name: busybox
        image: registry.k8s.io/e2e-test-images/busybox:1.29-4
        command:
        - "/bin/sleep"
        - "10000"
        volumeMounts:
        - name: secrets-store01-inline
          mountPath: "/mnt/secrets-store"
          readOnly: true
        env:
        - name: SYNCED_SECRET
          valueFrom:
            secretKeyRef:
              name: syncedsecret
              key: mysecret
      volumes:
      - name: secrets-store01-inline
        csi:
          driver: secrets-store.csi.k8s.io
          readOnly: true
          volumeAttributes:
            secretProviderClass: "azure-kvname-wi"
EOF

# Check the secret values 

# Get the pod name
POD_NAME=$(kubectl get pods -o jsonpath='{.items[0].metadata.name}')

# Check the environment variable
kubectl exec -it $POD_NAME -- /bin/sh -c 'echo $SYNCED_SECRET'

# Exec into the running pod
kubectl exec -it $POD_NAME -- /bin/sh -c 'cat /mnt/secrets-store/Secret'
```

Now that we've redployed with Reloader enabled, we can update the secret. It will take a minute or so for Reloader to see the change and then it will update reload the deployment.

```bash
# Update the secret
az keyvault secret set --vault-name $KV_NAME --name "Secret" --value "Synced with Reloader"

# Wait for the deployment to reload. You can watch the deployment with the following
watch kubectl get deploy

# Get the pod name
POD_NAME=$(kubectl get pods -o jsonpath='{.items[0].metadata.name}')

# Check the environment variable
kubectl exec -it $POD_NAME -- /bin/sh -c 'echo $SYNCED_SECRET'

# Exec into the running pod
kubectl exec -it $POD_NAME -- /bin/sh -c 'cat /mnt/secrets-store/Secret'
```

## Conclusion

While there are many many ways to handle secret updates, you should now have a better understanding of the moving parts and how they can work together.