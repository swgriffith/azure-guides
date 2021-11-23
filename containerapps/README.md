# Container Apps

This doc is just a subset of some of the content from the Azure Documentation around Azure Container Apps. For the full set of content, visit the Azure Docs [here](https://docs.microsoft.com/en-us/azure/container-apps/).

## Current Limitations

As Azure Container apps is still in early preview stages, there are still a number of limitations. Some will be addressed in the near term, while others likely wont be supported as they go beyond the scope of what Container Apps is trying to address.

- No support for Windows Containers (TBD on Roadmap)
- Vnet support (In progress)
- No ability to run priviledge containers (No planned support)
- 

## Basic Container App Deployment

Lets run through a very basic container app setup. Here we'll create the following:

- Resource Group
- Log Analytics Workspace
- Container App Environment
- Container App

```bash
az extension add \
--source https://workerappscliextension.blob.core.windows.net/azure-cli-extension/containerapp-0.2.0-py2.py3-none-any.whl

az provider register --namespace Microsoft.Web

# Set your Env Variables
RESOURCE_GROUP="EphContainerApps"
LOCATION="canadacentral"
LOG_ANALYTICS_WORKSPACE="containerapps-logs"
CONTAINERAPPS_ENVIRONMENT="containerapps-env"

# Create a Resource Group
az group create \
--name $RESOURCE_GROUP \
--location "$LOCATION"

# Create a Log Analytics Workspace
az monitor log-analytics workspace create \
--resource-group $RESOURCE_GROUP \
--workspace-name $LOG_ANALYTICS_WORKSPACE

# Get the Client ID and Secret for Log Analytics
LOG_ANALYTICS_WORKSPACE_CLIENT_ID=`az monitor log-analytics workspace show --query customerId -g $RESOURCE_GROUP -n $LOG_ANALYTICS_WORKSPACE --out tsv`

LOG_ANALYTICS_WORKSPACE_CLIENT_SECRET=`az monitor log-analytics workspace get-shared-keys --query primarySharedKey -g $RESOURCE_GROUP -n $LOG_ANALYTICS_WORKSPACE --out tsv`

# Create the Container App Environment
az containerapp env create \
--name $CONTAINERAPPS_ENVIRONMENT \
--resource-group $RESOURCE_GROUP \
--logs-workspace-id $LOG_ANALYTICS_WORKSPACE_CLIENT_ID \
--logs-workspace-key $LOG_ANALYTICS_WORKSPACE_CLIENT_SECRET \
--location "$LOCATION"

# Create the container app
az containerapp create \
--name myapp \
--resource-group $RESOURCE_GROUP \
--environment $CONTAINERAPPS_ENVIRONMENT \
--image docker.io/stevegriffith/appa:latest \
--target-port 80 \
--ingress 'external' \
--query configuration.ingress.fqdn
```

## Advanced Deployment with Bicep or ARM

At this early stage, many features you may want to use are not available yet in the Azure portal or via the CLI, so you'll need to work with ARM or Bicep scripts to deploy.

Let's deploy a container app with HTTP scaling enabled. You can find the [arm template](./containerapp.json) and [parameters file](./containerapp.parameters.json) in this folder. We're going to reuse the log analytics workspace we created above for this.

### Bicep

```bash
RG=EphCADemo
CA_NAME=testapp

az group create -n $RG -l canadacentral

az deployment group create -n container-app \
  -g $RG \
  --template-file ./containerapp.bicep \
  -p containerappName=$CA_NAME \
     environment_name=ca-env \
     location=canadacentral \
     log_analytics_name=cademola

```

### ARM

```bash
# Edit your containerapp.parameters.json to set the paramters for your deployment.

# Create the resource group
az group create -n EphContainerAppARM -l canadacentral

# Create the environment and container app
az deployment group create -g EphContainerAppARM -f containerapp.json -p @containerapp.parameters.json
```

Now lets test our app and the autoscaling we configured. For this, we'll watch the revision replica count and throw some traffic at the endpoint with [hey](https://github.com/rakyll/hey).

```bash
# Get your container app fqdn
echo 'url = https://'$(az containerapp show -g $RG -n $CA_NAME --query configuration.ingress.fqdn -o tsv)

# Watch the replica count
watch "az containerapp revision list -g $RG -n $CA_NAME --query '[].{Name:name, Replicas:replicas, FQDN:fqdn, TrafficWeight:trafficWeight, Image:template.containers[0].image}'"

# In another terminal, run hey against the FQDN
hey -z 2m <Insert URL>
```

## Revisions

Revisions are created when an container app

```bash
az containerapp revision list \
-g $RG \
-n $CA_NAME \
--query '[].{Name:name, Replicas:replicas, FQDN:fqdn, TrafficWeight:trafficWeight, Image:template.containers[0].image}' \
-o table
```


## Private Networking (NOT YET WORKING...but would look like this)

```bash
RESOURCE_GROUP="EphContainerApps"
LOCATION="canadacentral"
LOG_ANALYTICS_WORKSPACE="containerapps-logs"
CONTAINERAPPS_ENVIRONMENT="private-containerapp-env"
VNET_SUBNET_ID="/subscriptions/*******************/resourceGroups/EphContainerApps/providers/Microsoft.Network/virtualNetworks/container-app-env/subnets/containerapps"

LOG_ANALYTICS_WORKSPACE_CLIENT_ID=`az monitor log-analytics workspace show --query customerId -g $RESOURCE_GROUP -n $LOG_ANALYTICS_WORKSPACE --out tsv`

LOG_ANALYTICS_WORKSPACE_CLIENT_SECRET=`az monitor log-analytics workspace get-shared-keys --query primarySharedKey -g $RESOURCE_GROUP -n $LOG_ANALYTICS_WORKSPACE --out tsv`

az containerapp env create \
--name $CONTAINERAPPS_ENVIRONMENT \
--resource-group $RESOURCE_GROUP \
--logs-workspace-id $LOG_ANALYTICS_WORKSPACE_CLIENT_ID \
--logs-workspace-key $LOG_ANALYTICS_WORKSPACE_CLIENT_SECRET \
--location "$LOCATION" \
--subnet-resource-id "$VNET_SUBNET_ID"

# Create the container app
az containerapp create \
--name myapp-private \
--resource-group $RESOURCE_GROUP \
--environment $CONTAINERAPPS_ENVIRONMENT \
--image docker.io/stevegriffith/appa:latest \
--target-port 80 \
--ingress 'internal' \
--query configuration.ingress.fqdn
```