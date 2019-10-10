# Cluster Management Roles
When working with Azure Kubernetes Service there can be a lot of confusion about the access needed by the individuals managing the cluster as well as the roles required by the Service Principal used by the cluster itself to execute Azure operations (ex. Creating an Azure Public IP on a Service type=LoadBalancer). The following tries to break it down and demonstrate the minimal roles required for Cluster Administration. When I say Cluster Administration I'm referring to the following:

AKS Cluster:
- Creation
- Scale
- Upgrade
- Deletion 

**Note:** Within cluster management there are some permutations if you're attaching your cluster to a Virtual Network/Subnet that is in another Subscription or Resource Group. Likewise for connecting to Log Analytics or Storage in separate Subscriptions or Resource Groups.

## Summary of Roles
For those looking to skip the lengthy walk through below, here are the basic custom role definitions you need for Cluster management. Again, this does not include any changes you may choose to make to the Cluster Service Principal, which by default is granted Contributor rights on the MC_ Resource Group.

### Cluster Compute Management
This custom role provides the rights needed to create, upgrade and scale an AKS cluster for either Availability Sets (old way) or VM Scale Sets (new way).
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

Setup:
```bash
# Run the following, and use the json file name you used to save the above role
az role definition create --role-definition @aks-compute-mgmnt-role.json

# Assign to a user at the Cluster Resource Group scope
az role assignment create --assignee <AppID from cluster-owner-sp file> --scope "/subscriptions/<YourTargetSubscriptionID>/resourceGroups/<YourTargetAKSClusterResourceGroup>" --role "AKS Compute Mgr"
```

### Cluster Network Join
This custom role provides the rights needed to attach an AKS cluster to a subnet if the cluster creator does not yet have access.
```json
{
  "Name": "AKS Network Join",
  "IsCustom": true,
  "Description": "Can Join and AKS Cluster to a given vnet/subnet",
  "Actions": [
    "Microsoft.Resources/subscriptions/resourcegroups/read",
    "Microsoft.Network/virtualNetworks/subnets/join/action"
  ],
  "NotActions": [

  ],
  "AssignableScopes": [
    "/subscriptions/<Insert Your Subscription ID>"
  ]
}
```
Setup:
```bash
# Run the following, and use the json file name you used to save the above role
az role definition create --role-definition @aks-network-mgmnt-role.json

# Assign to a user at the subnet scope
az role assignment create --assignee b2615cc0-664c-4c48-9fdf-81ceacb86518 --scope "<Insert your Subnet ID from above>" --role "AKS Network Join"
```

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
1. In the cloud shell create a file named aks-compute-mgmnt-role.json, or whatever you prefer
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

Before you move on, you can clean up your cluster and service principals by running the following:
```bash
az aks delete -g EphClusterRoleTest -n testcluster -y --no-wait
az ad sp delete --id <AppID from cluster-owner-sp file>
az ad sp delete --id <AppID from cluster-internal-sp file>
```

## Cluster Creation with Subnet in Separate Sub or Resource Group
Since VM Scale Sets, or any VMs for that matter, need to join their NIC to a Subnet for network connectivity you will need network connectivity. If you run the commands above this isn't an issue because the commands above don't specify a target subnet, which means a VNet and Subnet are created in the MC_ resource group for you by the Azure Control Plane. However, if that VNet and Subnet are in a separate resource group or even a separate subscription, then you may not have rights to join a NIC to that network. The following outlines the process to validate the requirements.


Lets start by creating fresh service principals so we know there arent any roles bound yet.

```bash
# I'm creating each and writing to a file for later use, but feel free 
# to remove the redirection and grab the values yourself with copy/paste
az ad sp create-for-rbac --skip-assignment>cluster-owner-sp
az ad sp create-for-rbac --skip-assignment>cluster-internal-sp
```

We still have the "AKS Compute Mgr" role definition file we used above. Lets first apply that role, which we know works to our newly created cluster owner service principal, from the cluster-owner-sp file. We should also add the Cluster Admin role needed to get the Kubernetes credentials later.

```bash
az role assignment create --assignee <AppID from cluster-owner-sp file> --scope "/subscriptions/<YourTargetSubscriptionID>/resourceGroups/<YourTargetAKSClusterResourceGroup>" --role "AKS Compute Mgr"
az role assignment create --assignee <AppID from cluster-owner-sp file> --scope "/subscriptions/<YourTargetSubscriptionID>/resourceGroups/<YourTargetAKSClusterResourceGroup>" --role "Azure Kubernetes Service Cluster Admin Role"
```

Now lets attempt to create a cluster using a VNet and Subnet in another Resource Group, which we're not authorized to access. First we'll create the VNet and Subnet using the Azure CLI from the cloud shell.

```bash
# Create Resource Group for the vnet
az group create -n EphClusterRoleTest-Vnet -l eastus

# Create the Vnet and Subnet
az network vnet create -g EphClusterRoleTest-Vnet -n aks-test-vnet --address-prefixes10.100.0.0/16 --subnet-name aks-sub --subnet-prefixes 10.100.0.0/24

# Get the subnet ID to be used in cluster creation and save for later
az network vnet show -g EphClusterRoleTest-Vnet -n aks-test-vnet -o tsv --query subnets[0].id

##########################################
### Switch out of the cloud shell here ###
##########################################

# Login
az login --service-principal --username <AppID from cluster-owner-sp file> --password <Password from cluster-owner-sp file> --tenant <Insert your AAD Tenant ID>

# Attempt to create the clsuter in the new subnet
az aks create -g EphClusterRoleTest -n testcluster --service-principal <AppID from cluster-internal-sp file> --client-secret <Password from cluster-internal-sp file> --node-vm-size Standard_D2s_v3 --vnet-subnet-id '<Insert Subnet ID from above>'
```

After running the above command you should get an error that the current user doesnt have resrouce group read rights on the resource group containing the Vnet. Even if you were to address that issue you'd see an error that the user doesnt have rights to 'Microsoft.Network/virtualNetworks/subnets/join/action' on the subnet. So we need to address both of these requirements. 

In the cloud shell create a new file called 'aks-network-mgmnt-role.json'. In this file paste the following. Note that we again give a specific subscription ID, as you need to provide a minimal assignable scope, but we will further refine when we apply.

```json
{
  "Name": "AKS Network Join",
  "IsCustom": true,
  "Description": "Can Join and AKS Cluster to a given vnet/subnet",
  "Actions": [
    "Microsoft.Resources/subscriptions/resourcegroups/read",
    "Microsoft.Network/virtualNetworks/subnets/join/action"
  ],
  "NotActions": [

  ],
  "AssignableScopes": [
    "/subscriptions/<Insert Your Subscription ID>"
  ]
}
```

As we did previously, from the Azure CLI run the following to create the role, and then assign the role to your cluster owner service principal (i.e. the one from your cluster-owner-sp file). 

**Note:** The assignment scope below is the subnet ID where you plan to create this cluster. You could go higher (ex. VNet, Resource Group or Subscription), but lets keep it fine grained. Also notice that even though we granted resource group read, we only scoped to the subnet itself, which works fine. You dont need to give read to the whole resource group, just the subnet scope.

```bash
az role definition create --role-definition @aks-network-mgmnt-role.json

az role assignment create --assignee b2615cc0-664c-4c48-9fdf-81ceacb86518 --scope "<Insert your Subnet ID from above>" --role "AKS Network Join"
```

Try to deploy the cluster again. This time it should deploy successfully.

```bash
az aks create -g EphClusterRoleTest -n testcluster --service-principal 324cc3fe-3e28-472e-aa17-f6bf56e1f3cf --client-secret a6d25cc1-048e-4f17-a618-ecb4bce3509d --node-vm-size Standard_D2s_v3 --vnet-subnet-id '/subscriptions/62afe9fc-190b-4f18-95ac-e5426017d4c8/resourceGroups/EphClusterRoleTest/providers/Microsoft.Network/virtualNetworks/aks-test-vnet/subnets/aks-sub'
```

Now try to run some scale and upgrade operations as well. Both should also work.
```bash
az aks nodepool scale -g EphClusterRoleTest --cluster-name testcluster -n nodepool1 -c 4
az aks upgrade -g EphClusterRoleTest -n testcluster --kubernetes-version 1.14.5
```


Once again, before you move on, you can clean up your cluster and service principals by running the following:
```bash
az aks delete -g EphClusterRoleTest -n testcluster -y --no-wait
az ad sp delete --id <AppID from cluster-owner-sp file>
az ad sp delete --id <AppID from cluster-internal-sp file>
```

## ## Cluster Creation with the Log Analytics Workspace in a Separate Sub or Resource Group
Similar to the issue we addressed above for a VNet in a separate resource group or subscription, it's possible that you may enable monitoring and logging to an Azure Log Analytics workspace that could possibly be in a separate Resource Group or Subscription.

Lets again start by creating fresh service principals so we know there arent any roles bound yet.

```bash
# I'm creating each and writing to a file for later use, but feel free 
# to remove the redirection and grab the values yourself with copy/paste
az ad sp create-for-rbac --skip-assignment>cluster-owner-sp
az ad sp create-for-rbac --skip-assignment>cluster-internal-sp
```

We will again apply the Compute Manager and Cluster Admin roles we've applied before. For this excercise we'll leave off the VNet Role and just assume the VNet will be created in the MC_ resource group, per defaults.

```bash
az role assignment create --assignee <AppID from cluster-owner-sp file> --scope "/subscriptions/<YourTargetSubscriptionID>/resourceGroups/<YourTargetAKSClusterResourceGroup>" --role "AKS Compute Mgr"
az role assignment create --assignee <AppID from cluster-owner-sp file> --scope "/subscriptions/<YourTargetSubscriptionID>/resourceGroups/<YourTargetAKSClusterResourceGroup>" --role "Azure Kubernetes Service Cluster Admin Role"
```