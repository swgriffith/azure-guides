# Workload Identity - Windows Nodepool Walkthrough

The following walkthrough shows how you can using [Azure Workload Identity](https://azure.github.io/azure-workload-identity/docs/) with the [AKS Workload Identity](https://learn.microsoft.com/en-us/azure/aks/workload-identity-overview) add-on along with [MSAL](https://learn.microsoft.com/en-us/azure/active-directory/develop/reference-v2-libraries) on an AKS Windows Nodepool.

### Register for the preview

The managed add-on for Azure Workload Identity is still in preview, so we must first register for the preview.

```bash
# Add or update the Azure CLI aks preview extention
az extension add --name aks-preview
az extension update --name aks-preview

# Register for the preview feature
az feature register --namespace "Microsoft.ContainerService" --name "EnableWorkloadIdentityPreview"

# Check registration status
az feature list -o table --query "[?contains(name, 'Microsoft.ContainerService/EnableWorkloadIdentityPreview')].{Name:name,State:properties.state}"

# Refresh the provider
az provider register --namespace Microsoft.ContainerService
```

### Cluster Creation

Now lets create the AKS cluster with the OIDC Issure and Workload Identity add-on enabled.

```bash
RG=WorkloadIdentityRG
LOC=eastus
CLUSTER_NAME=wi-lab
WINDOWS_ADMIN_NAME=griffith

# Create the resource group
az group create -g $RG -l $LOC

# Create the cluster with the OIDC Issuer and Workload Identity enabled
az aks create -g $RG -n $CLUSTER_NAME \
--node-count 1 \
--enable-oidc-issuer \
--enable-workload-identity \
--generate-ssh-keys \
--windows-admin-username $WINDOWS_ADMIN_NAME \
--network-plugin azure

# Add a windows pool
az aks nodepool add \
--resource-group $RG \
--cluster-name $CLUSTER_NAME \
--os-type Windows \
--name npwin \
--node-count 1

# Get the cluster credentials
az aks get-credentials -g $RG -n $CLUSTER_NAME
```

### Set up the identity 

In order to federate a managed identity with a Kubernetes Service Account we need to get the AKS OIDC Issure URL, create the Managed Identity and Service Account and then create the federation.

```bash
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
  annotations:
    azure.workload.identity/client-id: ${USER_ASSIGNED_CLIENT_ID}
  labels:
    azure.workload.identity/use: "true"
  name: wi-demo-sa
  namespace: default
EOF

# Federate the identity
az identity federated-credential create \
--name wi-demo-federated-id \
--identity-name wi-demo-identity \
--resource-group $RG \
--issuer ${AKS_OIDC_ISSUER} \
--subject system:serviceaccount:default:wi-demo-sa
```

### Create the Key Vault and Secret

```bash
# Create a key vault
az keyvault create --name wi-demo-keyvault --resource-group $RG --location $LOC

# Create a secret
az keyvault secret set --vault-name wi-demo-keyvault --name "Secret" --value "Hello"

# Grant access to the secret for the managed identity
az keyvault set-policy --name wi-demo-keyvault --secret-permissions get --spn "${USER_ASSIGNED_CLIENT_ID}"

# Get the version ID
az keyvault secret show --vault-name wi-demo-keyvault --name "Secret" -o tsv --query id
https://wi-demo-keyvault.vault.azure.net/secrets/Secret/ded8e5e3b3e040e9bfa5c47d0e28848a

# The version ID is the last part of the resource id above
# We'll use this later
VERSION_ID=ded8e5e3b3e040e9bfa5c47d0e28848a
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
            string? versionID = Environment.GetEnvironmentVariable("VERSION_ID");;
            
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
            KeyVaultSecret secret = client.GetSecret(secretName, versionID);
            Console.WriteLine("Your secret is '" + secret.Value + "'.");
            System.Threading.Thread.Sleep(5000);
            }

        }
    }
```

Create a new Dockerfile with the following:

```bash
FROM mcr.microsoft.com/dotnet/sdk:7.0-windowsservercore-ltsc2019 AS build-env
WORKDIR /App

# Copy everything
COPY . ./
# Restore as distinct layers
RUN dotnet restore
# Build and publish a release
RUN dotnet publish -c Release -o out

# Build runtime image
FROM mcr.microsoft.com/dotnet/aspnet:7.0-windowsservercore-ltsc2019
WORKDIR /App
COPY --from=build-env /App/out .
ENTRYPOINT ["dotnet", "keyvault-console-app.dll"]
```

Build the image. I'll create an Azure Container Registry and build there, and then link that ACR to my AKS cluster.

```bash
# Create the ACR
az acr create -g $RG -n wikvdemo --sku Standard

# Build the image
az acr build -t wi-kv-test --platform windows -r wikvdemo .

# Link the ACR to the AKS cluster
az aks update -g $RG -n $CLUSTER_NAME --attach-acr wikvdemo
```

Now deploy a pod that gets the value using the service account identity.

```bash

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: wi-kv-test
  namespace: default
spec:
  nodeSelector:
    agentpool: npwin
  serviceAccountName: wi-demo-sa
  containers:
    - image: wikvdemo.azurecr.io/wi-kv-test
      name: wi-kv-test
      env:
      - name: KEY_VAULT_NAME
        value: wi-demo-keyvault
      - name: SECRET_NAME
        value: Secret
      - name: VERSION_ID
        value: ${VERSION_ID}       
  nodeSelector:
    kubernetes.io/os: linux
EOF

# Check the pod logs
kubectl logs -f wi-kv-test

# Sample Output
Retrieving your secret from wi-demo-keyvault.
Your secret is 'Hello'.
```

### Conclusion

Congrats! You should now have a working pod that uses MSAL along with a Kubernetes Service Account federated to an Azure Managed Identity to access and Azure Key Vault Secret.