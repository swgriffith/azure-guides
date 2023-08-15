# Accessing Azure SQL DB via Workload Identity and Managed Identity

## Introduction

In this walk through we'll create an AKS cluster enabled with Workload Identity. We'll then set up an Azure SQL DB and access it via Azure Managed Identity using Workload Identity from a Kubernetes pod.

## Setup

### Cluster Creation

Lets create the AKS cluster with the OIDC Issure and Workload Identity add-on enabled.

```bash
RG=WorkloadIdentitySQLRG
LOC=eastus
CLUSTER_NAME=wisqllab
UNIQUE_ID=$CLUSTER_NAME$RANDOM
ACR_NAME=$UNIQUE_ID
KEY_VAULT_NAME=$UNIQUE_ID

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

MANAGED_IDENTITY_NAME=wi-demo-identity

# Create the managed identity
az identity create --name $MANAGED_IDENTITY_NAME --resource-group $RG --location $LOC

# Get identity client ID
export USER_ASSIGNED_CLIENT_ID=$(az identity show --resource-group $RG --name $MANAGED_IDENTITY_NAME --query 'clientId' -o tsv)
export USER_ASSIGNED_OBJ_ID=$(az identity show --resource-group $RG --name $MANAGED_IDENTITY_NAME --query 'principalId' -o tsv)

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
--identity-name $MANAGED_IDENTITY_NAME \
--resource-group $RG \
--issuer ${AKS_OIDC_ISSUER} \
--subject system:serviceaccount:default:wi-demo-sa
```

### Create the Azure SQL DB Server and Database

```bash
# Create a single database and configure a firewall rule
UNIQUE_ID=$RANDOM
SERVER_NAME="widemo-$UNIQUE_ID"
DATABASE_NAME="widemo$UNIQUE_ID"
LOGIN="azureuser"
PASSWD="Pa$$w0rD-$UNIQUE_ID"
# Specify appropriate IP address values for your environment
# to limit access to the SQL Database server
MY_IP=$(curl icanhazip.com)

# Create the SQL Server Instance
az sql server create \
--name $SERVER_NAME \
--resource-group $RG \
--location $LOC \
--admin-user $LOGIN \
--admin-password $PASSWD

# Allow your ip through the server firewall
az sql server firewall-rule create \
--resource-group $RG \
--server $SERVER_NAME \
-n AllowYourIp \
--start-ip-address $MY_IP \
--end-ip-address $MY_IP

# Allow azure services through the server firewall
az sql server firewall-rule create \
--resource-group $RG \
--server $SERVER_NAME \
-n AllowAzureServices \
--start-ip-address 0.0.0.0 \
--end-ip-address 0.0.0.0

# Create the Database 
az sql db create --resource-group $RG --server $SERVER_NAME \
--name $DATABASE_NAME \
--sample-name AdventureWorksLT \
--edition GeneralPurpose \
--family Gen5 \
--capacity 2 \
--zone-redundant false 

# Get user info for adding admin user
SIGNED_IN_USER_OBJ_ID=$(az ad signed-in-user show -o tsv --query id)
SIGNED_IN_USER_DSP_NAME=$(az ad signed-in-user show -o tsv --query userPrincipalName)

# Add yourself as the Admin User
az sql server ad-admin create \
--resource-group $RG \
--server-name $SERVER_NAME \
--display-name $SIGNED_IN_USER_DSP_NAME \
--object-id $SIGNED_IN_USER_OBJ_ID

```

### Add a user to the database

For this step we'll need to use the [sqlcmd command line tool](https://learn.microsoft.com/en-us/sql/tools/sqlcmd/sqlcmd-utility?view=sql-server-ver16). You can install sqlcmd yourself, or you can use the [Azure Cloud Shell](https://shell.azure.com), which has it pre-installed for you.

```bash
# Get the server FQDN
DB_SERVER_FQDN=$(az sql server show -g $RG -n $SERVER_NAME -o tsv --query fullyQualifiedDomainName)

# Generate the user creation command
# Copy the output of the following to run against your SQL Server after logged in
echo "CREATE USER [${MANAGED_IDENTITY_NAME}] FROM EXTERNAL PROVIDER WITH OBJECT_ID='${USER_ASSIGNED_OBJ_ID}'"
echo "GO"
echo "ALTER ROLE db_datareader ADD MEMBER [${MANAGED_IDENTITY_NAME}]"
echo "GO"

# Login to the SQL DB via interactive login
sqlcmd -S $DB_SERVER_FQDN -d $DATABASE_NAME -G

##################################################
# Paste the command generated above to create the 
# User and grant the user reader access
# then type exit to leave the sqlcmd terminal
##################################################

```
## Create the sample app

```bash
# Create and test a new console app
dotnet new console -n sql-console-app
cd sql-console-app
dotnet run

# Add the Key Vault and Azure Identity Packages
dotnet add package Microsoft.Data.SqlClient
dotnet add package Azure.Identity
```

Edit the app Program.cs as follows:

```csharp
using Microsoft.Data.SqlClient;

namespace sqltest
{
    class Program
    {
        static void Main(string[] args)
        {
            string? dbServerFQDN = Environment.GetEnvironmentVariable("DB_SERVER_FQDN");;
            string? dbName = Environment.GetEnvironmentVariable("DATABASE_NAME");;
            
            while(true){
                try 
                { 
                    // For system-assigned managed identity
                    // Use your own values for Server and Database.
                    string ConnectionString = String.Format("Server={0}; Authentication=Active Directory Default; Encrypt=True; Database={1}",dbServerFQDN,dbName);

                    using (SqlConnection connection = new SqlConnection(ConnectionString)) {

                        Console.WriteLine("\nQuery data example:");
                        Console.WriteLine("=========================================\n");
                        
                        connection.Open();       

                        String sql = "SELECT TOP 5 FirstName, LastName FROM [SalesLT].[Customer]";

                        using (SqlCommand command = new SqlCommand(sql, connection))
                        {
                            using (SqlDataReader reader = command.ExecuteReader())
                            {
                                while (reader.Read())
                                {
                                    Console.WriteLine("{0} {1}", reader.GetString(0), reader.GetString(1));
                                }
                            }
                        }                    
                    }
                }
                catch (SqlException e)
                {
                    Console.WriteLine(e.ToString());
                }
            System.Threading.Thread.Sleep(10000);
            }
        }
    }
}
```

Create a new Dockerfile with the following.

> **NOTE:** Don't forget to check the dotnet version you used to generate your code by running 'dotnet --version' and make sure the base container image matches. For example, my dotnet version was 7.0.102 when I wrote this, so I used sdk 7.0.

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
ENTRYPOINT ["dotnet", "sql-console-app.dll"]
```

Build the image. I'll create an Azure Container Registry and build there, and then link that ACR to my AKS cluster.

```bash
# Create the ACR
az acr create -g $RG -n $ACR_NAME --sku Standard

# Build the image
az acr build -t wi-sql-test -r $ACR_NAME .

# Link the ACR to the AKS cluster
az aks update -g $RG -n $CLUSTER_NAME --attach-acr $ACR_NAME
```

Now deploy a pod that gets the value using the service account identity.

```bash

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: wi-sql-test
  namespace: default
  labels:
    azure.workload.identity/use: "true"  
spec:
  serviceAccountName: wi-demo-sa
  containers:
    - image: ${ACR_NAME}.azurecr.io/wi-sql-test
      name: wi-sql-test
      env:
      - name: DB_SERVER_FQDN
        value: ${DB_SERVER_FQDN}
      - name: DATABASE_NAME
        value: ${DATABASE_NAME}
      imagePullPolicy: Always   
  nodeSelector:
    kubernetes.io/os: linux
EOF

# Check the pod logs
kubectl logs -f wi-sql-test

```
