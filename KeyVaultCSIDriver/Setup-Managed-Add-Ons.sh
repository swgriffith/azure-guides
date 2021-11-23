# NOTE: This is intended to be run as copy/past3
# Do not just execute the script, as there are some delays
# in identity creation and propegation not accounted for.

# Set ENV Variables
export RG=<InsertResourceGroup>
export LOC=eastus
export CLUSTER_NAME=<InsertClusterName>
export KV_NAME=<InsertKeyVaultName>
export SUBID="<InsertSubscriptionID>"
export TENANTID="<InsertTenantID>"

# Register Previews
az feature register --name EnablePodIdentityPreview --namespace Microsoft.ContainerService
az feature register --namespace "Microsoft.ContainerService" --name "AKS-AzureKeyVaultSecretsProvider"

# Watch for previews to be in 'Registered' status
# Once both are registered you can move on.
az feature list -o table --query "[?contains(name, 'Microsoft.ContainerService/EnablePodIdentityPreview')].{Name:name,State:properties.state}"
az feature list -o table --query "[?contains(name, 'Microsoft.ContainerService/AKS-AzureKeyVaultSecretsProvider')].{Name:name,State:properties.state}"

# Install the aks-preview extension
az extension add --name aks-preview
az extension update --name aks-preview

# Create Resource Group
az group create -n $RG -l $LOC

# Create Cluster with Managed Identity Enabled
az aks create -n $CLUSTER_NAME -g $RG --node-count 1 --enable-pod-identity --enable-addons azure-keyvault-secrets-provider --network-plugin azure

# Get Cluster Credentials
az aks get-credentials -g $RG -n $CLUSTER_NAME

# Get the Cluster Identity
export CLUSTER_IDENTITY=$(az aks show -g $RG -n $CLUSTER_NAME -o tsv --query identityProfile.kubeletidentity.clientId)

# Get Node Pool Resource Group
export NODE_RESOURCE_GROUP=$(az aks show -g $RG -n $CLUSTER_NAME -o tsv --query nodeResourceGroup)

# Create Key Vault and secret
az keyvault create --name $KV_NAME --resource-group $RG --location $LOC

# Get Kevy Vault ID for later use
export KV_ID=$(az keyvault show -g $RG -n $KV_NAME -o tsv --query id)

# Create a test secret
az keyvault secret set --vault-name $KV_NAME --name "ExamplePassword" --value "FuzzyBunny"
az keyvault secret show --name "ExamplePassword" --vault-name $KV_NAME

# Grant rights to the cluster Identity for Pod Identity
az role assignment create --role "Managed Identity Operator" --assignee $CLUSTER_IDENTITY --scope /subscriptions/$SUBID/resourcegroups/$NODE_RESOURCE_GROUP
az role assignment create --role "Virtual Machine Contributor" --assignee $CLUSTER_IDENTITY --scope /subscriptions/$SUBID/resourcegroups/$NODE_RESOURCE_GROUP

# Create an Identity for use with Pod Identity
export IDENTITY_NAME=testident
az identity create -g $NODE_RESOURCE_GROUP -n $IDENTITY_NAME 

# Get the identity details
export IDENTITY_CLIENT_ID="$(az identity show -g $NODE_RESOURCE_GROUP -n $IDENTITY_NAME --query clientId -otsv)"
export IDENTITY_RESOURCE_ID="$(az identity show -g $NODE_RESOURCE_GROUP -n $IDENTITY_NAME --query id -otsv)"

# Grant the identity rights on the Key Vault
# NOTE: It may take a few minutes before the identity is ready to assign a role
# You may get an error finding the identity in this case.
# Give it a minute and retry
az role assignment create --role "Reader" --assignee $IDENTITY_CLIENT_ID --scope $KV_ID
az keyvault set-policy --name $KV_NAME --spn $IDENTITY_CLIENT_ID --secret-permissions get

# Generate the SecretProviderClass.yaml file with the right values filled in
cat <<EOF >> SecretProviderClass.yaml
apiVersion: secrets-store.csi.x-k8s.io/v1alpha1
kind: SecretProviderClass
metadata:
  name: azure-$KV_NAME
spec:
  provider: azure
  parameters:
    usePodIdentity: "true"                   # [REQUIRED] Set to "true" if using managed identities
    useVMManagedIdentity: "false"             # [OPTIONAL] if not provided, will default to "false"
    userAssignedIdentityID: "$IDENTITY_CLIENT_ID"       # [REQUIRED] If you're using a service principal, use the client id to specify which user-assigned managed identity to use. If you're using a user-assigned identity as the VM's managed identity, specify the identity's client id. If the value is empty, it defaults to use the system-assigned identity on the VM
                                                             #     az ad sp show --id http://contosoServicePrincipal --query appId -o tsv
                                                             #     the preceding command will return the client ID of your service principal
    keyvaultName: "$KV_NAME"          # [REQUIRED] the name of the key vault
                                              #     az keyvault show --name contosoKeyVault5
                                              #     the preceding command will display the key vault metadata, which includes the subscription ID, resource group name, key vault 
    cloudName: ""          			          # [OPTIONAL for Azure] if not provided, Azure environment will default to AzurePublicCloud
    objects:  |
      array:
        - |
          objectName: ExamplePassword                 # [REQUIRED] object name
                                              #     az keyvault secret list --vault-name “contosoKeyVault5”
                                              #     the above command will display a list of secret names from your key vault
          objectType: secret                  # [REQUIRED] object types: secret, key, or cert
          objectVersion: ""                   # [OPTIONAL] object versions, default to latest if empty
    resourceGroup: "$RG"     # [REQUIRED] the resource group name of the key vault
    subscriptionId: "$SUBID"          # [REQUIRED] the subscription ID of the key vault
    tenantId: "$TENANTID"                      # [REQUIRED] the tenant ID of the key vault
EOF

# Apply the SecreteProviderClass.yaml
kubectl apply -f SecretProviderClass.yaml

az aks pod-identity add --resource-group $RG --cluster-name $CLUSTER_NAME --namespace default --name $IDENTITY_NAME --identity-resource-id $IDENTITY_RESOURCE_ID

# Create a Test Pod yamls file with the right values
cat << EOF >> TestPod.yaml
kind: Pod
apiVersion: v1
metadata:
  name: nginx-secrets-store-inline
  labels:
    aadpodidbinding: $IDENTITY_NAME
spec:
  containers:
  - name: nginx
    image: nginx
    volumeMounts:
    - name: secrets-store-inline
      mountPath: "/mnt/secrets-store"
      readOnly: true
  volumes:
  - name: secrets-store-inline
    csi:
      driver: secrets-store.csi.k8s.io
      readOnly: true
      volumeAttributes:
        secretProviderClass: azure-$KV_NAME
EOF

# Start the test pod
kubectl apply -f TestPod.yaml

# Test that that secret was mounted properly
kubectl exec -it nginx-secrets-store-inline -- cat /mnt/secrets-store/ExamplePassword
