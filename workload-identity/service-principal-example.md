# Workload Identity - Service Principal

The following walkthrough shows how you can using [Azure Workload Identity](https://azure.github.io/azure-workload-identity/docs/) with the [AKS Workload Identity](https://learn.microsoft.com/en-us/azure/aks/workload-identity-overview) add-on along with [MSAL](https://learn.microsoft.com/en-us/azure/active-directory/develop/reference-v2-libraries), but instead of a managed identity we'll use a service principal.

### Cluster Creation

Lets create the AKS cluster with the OIDC Issurer and Workload Identity add-on enabled.

```bash
RG=WorkloadIdentitySPRG
LOC=eastus
CLUSTER_NAME=wisplab
UNIQUE_ID=$CLUSTER_NAME$RANDOM
ACR_NAME=$UNIQUE_ID
KEY_VAULT_NAME=$UNIQUE_ID
TENANT_ID=$(az account show -o tsv --query tenantId)

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

In order to federate a managed identity with a Kubernetes Service Account we need to get the AKS OIDC Issure URL, create the Service Principal and Service Account and then create the federation.

```bash
# Get the OIDC Issuer URL
export AKS_OIDC_ISSUER="$(az aks show -n $CLUSTER_NAME -g $RG --query "oidcIssuerProfile.issuerUrl" -otsv)"

# Create the service principal and get the app and object IDs for later
SP_APP_ID=$(az ad sp create-for-rbac --skip-assignment --display-name akswidemosp --query appId -o tsv)
SP_APP_OBJ_ID=$(az ad app show --id $SP_APP_ID -o tsv --query id)

# Create a service account to federate with the managed identity
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  annotations:
    azure.workload.identity/client-id: ${SP_APP_ID}
  labels:
    azure.workload.identity/use: "true"
  name: wi-sp-demo-sa
  namespace: default
EOF

# Generate the input file for the Service Principal App Federation
cat <<EOF > params.json
{
  "name": "kubernetes-federated-identity",
  "issuer": "${AKS_OIDC_ISSUER}",
  "subject": "system:serviceaccount:default:wi-sp-demo-sa",
  "description": "Kubernetes service account federated identity",
  "audiences": [
    "api://AzureADTokenExchange"
  ]
}
EOF

# Create the app identity federation
az ad app federated-credential create --id $SP_APP_OBJ_ID --parameters params.json
```

### Create the Key Vault and Secret

```bash
# Create a key vault
az keyvault create --name $KEY_VAULT_NAME --resource-group $RG --location $LOC

# Create a secret
az keyvault secret set --vault-name $KEY_VAULT_NAME --name "Secret" --value "Hello Service Principal"

# Grant access to the secret for the managed identity
az keyvault set-policy --name $KEY_VAULT_NAME -g $RG --secret-permissions get --spn "${SP_APP_OBJ_ID}"
```

## Create the sample app

```bash
# Create and test a new console app
dotnet new console -n keyvault-console-app
cd keyvault-console-app
dotnet run

# Add the Key Vault and Azure Identity Packages
dotnet add package Azure.Security.KeyVault.Secrets
dotnet add package Azure.Identity
```

Edit the app as follows:

```csharp
using System;
using System.IO;
using Azure.Core;
using Azure.Identity;
using Azure.Security.KeyVault.Secrets;

class Program
    {
        static void Main(string[] args)
        {
            //Get env variables
            string? secretName = Environment.GetEnvironmentVariable("SECRET_NAME");;
            string? keyVaultName = Environment.GetEnvironmentVariable("KEY_VAULT_NAME");;
            
            //Create Key Vault Client
            var kvUri = String.Format("https://{0}.vault.azure.net", keyVaultName);
            SecretClientOptions options = new SecretClientOptions()
            {
                Retry =
                {
                    Delay= TimeSpan.FromSeconds(2),
                    MaxDelay = TimeSpan.FromSeconds(16),
                    MaxRetries = 5,
                    Mode = RetryMode.Exponential
                 }
            };

            var client = new SecretClient(new Uri(kvUri), new DefaultAzureCredential(),options);

            // Get the secret value in a loop
            while(true){
            Console.WriteLine("Retrieving your secret from " + keyVaultName + ".");
            KeyVaultSecret secret = client.GetSecret(secretName);
            Console.WriteLine("Your secret is '" + secret.Value + "'.");
            System.Threading.Thread.Sleep(5000);
            }

        }
    }
```

Create a new Dockerfile with the following:

```bash
FROM mcr.microsoft.com/dotnet/sdk:7.0 AS build-env
WORKDIR /App

# Copy everything
COPY . ./
# Restore as distinct layers
RUN dotnet restore
# Build and publish a release
RUN dotnet publish -c Release -o out

# Build runtime image
FROM mcr.microsoft.com/dotnet/aspnet:7.0
WORKDIR /App
COPY --from=build-env /App/out .
ENTRYPOINT ["dotnet", "keyvault-console-app.dll"]
```

Build the image. I'll create an Azure Container Registry and build there, and then link that ACR to my AKS cluster.

```bash
# Create the ACR
az acr create -g $RG -n $ACR_NAME --sku Standard

# Build the image
az acr build -t wi-kv-test -r $ACR_NAME -g $RG .

# Link the ACR to the AKS cluster
az aks update -g $RG -n $CLUSTER_NAME --attach-acr $ACR_NAME
```

Now deploy a pod that gets the value using the service account identity.

```bash

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: wi-kv-test
  namespace: default
  labels:
    azure.workload.identity/use: "true"  
spec:
  serviceAccountName: wi-sp-demo-sa
  containers:
    - image: ${ACR_NAME}.azurecr.io/wi-kv-test
      name: wi-kv-test
      env:
      - name: KEY_VAULT_NAME
        value: ${KEY_VAULT_NAME}
      - name: SECRET_NAME
        value: Secret    
  nodeSelector:
    kubernetes.io/os: linux
EOF

# Check the pod logs
kubectl logs -f wi-kv-test

# Sample Output
Retrieving your secret from wi-demo-keyvault.
Your secret is 'Hello Service Principal'.
```

### Conclusion

Congrats! You should now have a working pod that uses MSAL along with a Kubernetes Service Account federated to an Azure Service Principal to access and Azure Key Vault Secret.
