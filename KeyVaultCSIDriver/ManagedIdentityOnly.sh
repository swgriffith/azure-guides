############################################
# Steps for customers using Managed Identity
# Only.
############################################

# Grant the identity rights on the Key Vault
az role assignment create --role "Reader" --assignee $CLUSTER_IDENTITY --scope $KV_ID
az keyvault set-policy --name $KV_NAME --spn $CLUSTER_IDENTITY --secret-permissions get

# Generate the SecretProviderClass.yaml file with the right values filled in
cat <<EOF >> SecretProviderClass.yaml
apiVersion: secrets-store.csi.x-k8s.io/v1alpha1
kind: SecretProviderClass
metadata:
  name: azure-$KV_NAME
spec:
  provider: azure
  parameters:
    usePodIdentity: "false"                   # [REQUIRED] Set to "true" if using managed identities
    useVMManagedIdentity: "true"             # [OPTIONAL] if not provided, will default to "false"
    userAssignedIdentityID: "$CLUSTER_IDENTITY"       # [REQUIRED] If you're using a service principal, use the client id to specify which user-assigned managed identity to use. If you're using a user-assigned identity as the VM's managed identity, specify the identity's client id. If the value is empty, it defaults to use the system-assigned identity on the VM
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
