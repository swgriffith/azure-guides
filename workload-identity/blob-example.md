# Workload Identity to Blob Storage

The following walkthrough shows how you can using [Azure Workload Identity](https://azure.github.io/azure-workload-identity/docs/) with the [AKS Workload Identity](https://learn.microsoft.com/en-us/azure/aks/workload-identity-overview) add-on along with [MSAL](https://learn.microsoft.com/en-us/azure/active-directory/develop/reference-v2-libraries) to access an Azure Blob Storage Account.

### Cluster Creation

Now lets create the AKS cluster with the OIDC Issure and Workload Identity add-on enabled.

```bash
RG=WorkloadIdentityRG
LOC=eastus
CLUSTER_NAME=wilab
UNIQUE_ID=$CLUSTER_NAME$RANDOM
ACR_NAME=$UNIQUE_ID
STORAGE_ACCT_NAME=griffdemo

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

### Create the Blob Storage Account

```bash
# Create a blob storage account
az storage account create \
--name $STORAGE_ACCT_NAME \
--resource-group $RG \
--location $LOC \
--sku Standard_LRS \
--encryption-services blob

# Get the resource ID of the storage account
STORAGE_ACCT_ID=$(az storage account show -g $RG -n $STORAGE_ACCT_NAME --query id -o tsv)

# Get the current signed in user ID
CURRENT_USER=$(az ad signed-in-user show --query id -o tsv)

# Grant the current user contributor rights for testing
az role assignment create \
--role "Storage Blob Data Contributor" \
--assignee $CURRENT_USER \
--scope "${STORAGE_ACCT_ID}"

# Grant the managed identity contributor rights
az role assignment create \
--role "Storage Blob Data Contributor" \
--assignee $USER_ASSIGNED_CLIENT_ID \
--scope "${STORAGE_ACCT_ID}"

# Create a storage account container with login auth mode enabled
az storage container create --account-name $STORAGE_ACCT_NAME --name data --auth-mode login
```

## Create the sample app

```bash
# Create and test a new console app
dotnet new console -n blob-console-app
cd blob-console-app
dotnet run

# Add the Key Vault and Azure Identity Packages
dotnet add package Azure.Storage.Blobs
dotnet add package Azure.Identity
```

Edit the app as follows:

```csharp
using Azure.Storage.Blobs;
using Azure.Storage.Blobs.Models;
using System;
using System.IO;
using Azure.Identity;

class Program
    {
        static void Main(string[] args)
        {
                      // Get Storage Account Name
          string? storageAcctName = Environment.GetEnvironmentVariable("STORAGE_ACCT_NAME");;
          string? containerName = Environment.GetEnvironmentVariable("CONTAINER_NAME");;

          if (string.IsNullOrEmpty(storageAcctName)||string.IsNullOrEmpty(containerName))
          {
            Console.WriteLine("Storage Account or Container Name are null or empty");
            Environment.Exit(0);
          }

          while (true)
          {
            MainAsync(storageAcctName,containerName).Wait();
            System.Threading.Thread.Sleep(5000);
          }
          
        }

        static async Task MainAsync(string storageAcctName, string containerName)
        {
          var blobServiceClient = new BlobServiceClient(
                  new Uri(String.Format("https://{0}.blob.core.windows.net",storageAcctName)),
                  new DefaultAzureCredential());

          BlobContainerClient containerClient = blobServiceClient.GetBlobContainerClient(containerName);

          // Create a local file in the ./data/ directory for uploading and downloading
          string localPath = "data";
          Directory.CreateDirectory(localPath);
          string fileName = Guid.NewGuid().ToString() + ".txt";
          string localFilePath = Path.Combine(localPath, fileName);

          // Write text to the file
          await File.WriteAllTextAsync(localFilePath, "Hello, World!");

          // Get a reference to a blob
          BlobClient blobClient = containerClient.GetBlobClient(fileName);

          Console.WriteLine("Uploading to Blob storage as blob:\n\t {0}\n", blobClient.Uri);

          // Upload data from the local file
          await blobClient.UploadAsync(localFilePath, true);
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
ENTRYPOINT ["dotnet", "blob-console-app.dll"]
```

Build the image. I'll create an Azure Container Registry and build there, and then link that ACR to my AKS cluster.

```bash
# Create the ACR
az acr create -g $RG -n $ACR_NAME --sku Standard

# Build the image
az acr build -t wi-blob-test -r $ACR_NAME .

# Link the ACR to the AKS cluster
az aks update -g $RG -n $CLUSTER_NAME --attach-acr $ACR_NAME
```

Now deploy a pod that runs our blob storage app using the service account identity.

```bash

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: wi-blob-test
  namespace: default
  labels:
    azure.workload.identity/use: "true"  
spec:
  serviceAccountName: wi-demo-sa
  containers:
    - image: ${ACR_NAME}.azurecr.io/wi-blob-test
      name: wi-blob-test
      env:
      - name: STORAGE_ACCT_NAME
        value: ${STORAGE_ACCT_NAME}
      - name: CONTAINER_NAME
        value: data      
  nodeSelector:
    kubernetes.io/os: linux
EOF

# Check the pod logs
kubectl logs -f wi-blob-test

# Sample Output
Uploading to Blob storage as blob:
	 https://griffdemo.blob.core.windows.net/data/quickstart3efa9a81-9672-4617-a6ff-f11fb93d7c84.txt

Uploading to Blob storage as blob:
	 https://griffdemo.blob.core.windows.net/data/quickstart23968d6b-80c5-4c82-8bcf-860fa00edbd3.txt

Uploading to Blob storage as blob:
	 https://griffdemo.blob.core.windows.net/data/quickstart0e20e7ef-c3ba-4fd3-a3d5-c27579d2ba96.txt
```

### Conclusion

Congrats! You should now have a working pod that uses MSAL along with a Kubernetes Service Account federated to an Azure Managed Identity to access Azure Blob Storage.