# AKS Fleet Manager Upgrades

## Cluster Setup

```bash
RG=EphFleetUpgradeDem0
LOC=eastus2
FLEET=fleetlab

# Create the resource group
az group create -g $RG -l $LOC

# Create the fleet
az fleet create --resource-group $RG --name ${FLEET} --location $LOC

# Create some AKS clusters
az aks create -g $RG -n dev-canary -c 1 --no-wait
az aks create -g $RG -n dev -c 1 --no-wait
az aks create -g $RG -n test-canary -c 1 --no-wait
az aks create -g $RG -n test -c 1 --no-wait
az aks create -g $RG -n stg-canary -c 1 --no-wait
az aks create -g $RG -n stg -c 1 --no-wait
az aks create -g $RG -n prd -c 1 --no-wait

az fleet member create \
--resource-group $RG \
--fleet-name $FLEET \
--name dev-canary \
--member-cluster-id $(az aks show -g $RG -n dev-canary --query id -o tsv) \
--no-wait

az fleet member create \
--resource-group $RG \
--fleet-name $FLEET \
--name dev \
--member-cluster-id $(az aks show -g $RG -n dev --query id -o tsv) \
--no-wait

az fleet member create \
--resource-group $RG \
--fleet-name $FLEET \
--name test-canary \
--member-cluster-id $(az aks show -g $RG -n test-canary --query id -o tsv) \
--no-wait

az fleet member create \
--resource-group $RG \
--fleet-name $FLEET \
--name test \
--member-cluster-id $(az aks show -g $RG -n test --query id -o tsv) \
--no-wait

az fleet member create \
--resource-group $RG \
--fleet-name $FLEET \
--name stg-canary \
--member-cluster-id $(az aks show -g $RG -n stg-canary --query id -o tsv) \
--no-wait

az fleet member create \
--resource-group $RG \
--fleet-name $FLEET \
--name stg \
--member-cluster-id $(az aks show -g $RG -n stg --query id -o tsv) \
--no-wait

az fleet member create \
--resource-group $RG \
--fleet-name $FLEET \
--name prd \
--member-cluster-id $(az aks show -g $RG -n prd --query id -o tsv) \
--no-wait

az aks get-credentials -g $RG -n dev-canary
az aks get-credentials -g $RG -n dev
az aks get-credentials -g $RG -n test-canary
az aks get-credentials -g $RG -n test
az aks get-credentials -g $RG -n stg-canary
az aks get-credentials -g $RG -n stg
az aks get-credentials -g $RG -n prd
```