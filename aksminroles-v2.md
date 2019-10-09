# Cluster Management Roles
When working with Azure Kubernetes Service there can be a lot of confusion about the access needed by the individuals managing the cluster as well as the roles required by the Service Principal used by the cluster itself to execute Azure operations (ex. Creating an Azure Public IP on a Service type=LoadBalancer). The following tries to break it down and demonstrate the minimal roles required for Cluster Administration. When I say Cluster Administration I'm referring to the following:

AKS Cluster:
- Creation
- Scale
- Upgrade
- Deletion 

**Note:** Within cluster management there are some permutations if you're attaching your cluster to a Virtual Network/Subnet that is in another Subscription or Resource Group. Likewise for connecting to Log Analytics or Storage in separate Subscriptions or Resource Groups.

## Summary of Roles
Fill in Later...

## Basic Cluster Creation
The First walk through will be the creation of a basic cluster where we're not attaching to any Network, Storage or Log Analytics instances outside of the MC_ resource group. This is the most straight forward as far as required roles and assigned scopes.

Create Service Principals for Cluster Admin user and Cluster internal user
```bash
# I'm creating each and writing to a file for later use, but feel free 
# to remove the redirection and grab the values yourself with copy/paste
az ad sp create-for-rbac --skip-assignment>cluster-owner-sp
az ad sp create-for-rbac --skip-assignment>cluster-internal-sp
```

Create the role definition for compute managment (Cluster Create, Upgrade, Scale **...but not Delete**)
1. Create a file named aks-compute-mgmnt-role.json, or whatever you prefer
1. Open the file and paste the following:
    ```json
    {
    "Name": "AKS Compute Mgr",
    "IsCustom": true,
    "Description": "Grants actions required to create and manage aks compute",
    "Actions": [
        "Microsoft.Resources/subscriptions/resourcegroups/read",
        "Microsoft.ContainerService/managedClusters/write",
        "Microsoft.ContainerService/managedClusters/read",
        "Microsoft.ContainerService/managedClusters/agentPools/write",
        "Microsoft.ContainerService/managedClusters/agentPools/read"
    ],
    "NotActions": [

    ],
    "AssignableScopes": [
        "/subscriptions/<Insert Target Subscription or Mgmnt Group ID>"
    ]
    }
    ```
    **Note:** You MUST provide an assignable scope, however you will assign a more specific scope when you assign this to a user, so don't worry about the broad scoping just yet.

1. From the Azure CLI run the following to create the role (Note: The @ lets you feed a file into the command parameter)
```bash
az role definition create --role-definition @aks-compute-mgmnt-role.json
```

Create target resource group
```bash
az group create -n EphClusterRoleTest -l eastus
```
Assign Compute Mgmnt role to Cluster Admin SP (Note: Use the [Cloud Shell](https://shell.azure.com) here.)
```bash
az role assignment create --assignee <AppID from cluster-owner-sp file> --scope "/subscriptions/<YourTargetSubscriptionID>/resourceGroups/<YourTargetAKSClusterResourceGroup>" --role "AKS Compute Mgr"
```

Open a new CLI session (Note: Consider running this from a local install of the CLI so you can run both the cloud shell and cli separately withouth needing to keep logging in and out.)
```bash
# Login
az login --service-principal --username <AppID from cluster-owner-sp file> --password <Password from cluster-owner-sp file> --tenant <Insert your AAD Tenant ID>
```

Try to create a cluster with network in same RG (i.e. none specified) and no custom log analytics
```bash
az aks create -g EphClusterRoleTest -n testcluster --service-principal <AppID from cluster-internal-sp file> --client-secret <Password from cluster-internal-sp file> --node-vm-size Standard_D2s_v3
# Cluster Creation should succeed
```
***Note:** The above creation will grant the cluster-internal service principal that you provided 'Contributor' rights on the Resource Group (MC_) created during cluster creation. That is by design, and while modification of those rights is possible it is not supported by the product at this time.*

Test getting credentials for kubectl
```bash 
az aks get-credentials -g EphClusterRoleTest -n testcluster -a  
```
The above will be denied because user does not have either of the following roles:
- "Azure Kubernetes Service Cluster Admin Role"
- "Azure Kubernetes Service Cluster User Role"

Grant user "Azure Kubernetes Service Cluster Admin Role"
```bash
az role assignment create --assignee <AppID from cluster-owner-sp file> --scope "/subscriptions/<YourTargetSubscriptionID>/resourceGroups/<YourTargetAKSClusterResourceGroup>" --role "Azure Kubernetes Service Cluster Admin Role"
```

Test getting credentials again
```bash 
az aks get-credentials -g EphClusterRoleTest -n testcluster -a 
```

Test Upgrade and Scale Operations
```bash
az aks nodepool scale -g EphClusterRoleTest --cluster-name testcluster -n nodepool1 -c 4
az aks upgrade -g EphClusterRoleTest -n testcluster --kubernetes-version 1.14.5
# Both Should succeed
```

Thats it. You now have a role definition with the minimum roles required to Create, Scale and Upgrade a basic AKS cluster. In the next sections we'll get into custom Network, Storage and Log Analytics resources, as well as the Cluster Delete role.
