# AKS Node Public IP
This guide demonstrates how to create an AKS cluster with a public IP assigned to each node. You can find the Azure doc [here](https://docs.microsoft.com/en-us/azure/aks/use-multiple-node-pools#assign-a-public-ip-per-node-in-a-node-pool).

## Setup
Cluster creation requires a few values be created and set in the azuredeploy.parameters.json.

### Deployment Parameters
- *clusterName:* Uniquely identifies your cluster within a resource group
- *dnsprefix:* unique name used for the kubernetes api server FQDN. Should be as unique as possible, lowercase and alphanumeric.
- *agentCount:* number of nodes that should be deployed
- *agentVMSize:* Virtual machine size used for the nodes
- *linuxAdminUsername:* admin user name assigned to the nodes used if you ssh into the nodes for diagnostics
- *sshRSAPublicKey:* ssh key used if you need to connect to the nodes via ssh for diagnostic reasons. You can generate a public key with ssh-keygen
- *servicePrincipalClientId:* App ID for the cluster service principal. Generated via steps below.
- *servicePrincipalClientSecret:* Password for the service principal. See steps below

1. Register for the preview feature
```bash
az feature register --name NodePublicIPPreview --namespace Microsoft.ContainerService

# Check registration status (may take up to 30min to register)
az feature show --namespace Microsoft.ContainerService --name NodePublicIPPreview

# Once registered you need to refresh the provider
az provider register --namespace Microsoft.ContainerService
```

1. Generate ssh key
    ```bash
    # Run ssh-keygen to generate an ssh key for the cluster
    ssh-keyget

    # Get the public key from the generated key
    cat ~/.ssh/id_rsa.pub
    ```
1. Generate service principal for the cluster
    ```bash
    az ad sp create-for-rbac --skip-assignment -o json

    # Example output
    {
    "appId": "sdfsdsd-ac68-4a3b-a936-sdfsdfsdfds",
    "displayName": "azure-cli-2020-03-25-02-54-39",
    "name": "http://azure-cli-2020-03-25-02-54-39",
    "password": "sdffsddd-042c-4d36-9b0c-sdfsdfdsfsdf",
    "tenant": "4fdsf4-86f1-41af-91ab-asdfsdfsdf"
    }
    ```

1. Update the azuredeploy.parameters.json with the ssh key, app id, password and any other values you want to adjust.

1. Deploy the cluster
    ```bash
    chmod +x clustercreate.sh
    ./clustercreate.sh
    ```
1. After creation completes, check the nodes have external ips
```bash
# Get your AKS cluster credentials
az aks get-credentials -g <Resrouce Group Name> -n <Cluster Name>

# Check the nodes have 'External IPs' assigned
kubectl get nodes -o wide
NAME                                STATUS   ROLES   AGE     VERSION    INTERNAL-IP   EXTERNAL-IP      OS-IMAGE             KERNEL-VERSION      CONTAINER-RUNTIME
aks-nodepool1-37394874-vmss000000   Ready    agent   3m3s    v1.15.10   10.240.0.4    40.121.148.106   Ubuntu 16.04.6 LTS   4.15.0-1071-azure   docker://3.0.10+azure
aks-nodepool1-37394874-vmss000001   Ready    agent   3m7s    v1.15.10   10.240.0.5    40.121.149.70    Ubuntu 16.04.6 LTS   4.15.0-1071-azure   docker://3.0.10+azure
aks-nodepool1-37394874-vmss000002   Ready    agent   3m28s   v1.15.10   10.240.0.6    40.121.144.56    Ubuntu 16.04.6 LTS   4.15.0-1071-azure   docker://3.0.10+azure
```

