# AKS Advanced Container Networking Service (ACNS)

## Setup

```bash
RG=EphACNSLab
LOC=eastus2
CLUSTER_NAME=acnslab
AZURE_MONITOR_NAME="acnslab"
GRAFANA_NAME="acnslab"

az group create -n $RG -l $LOC

# Create an AKS cluster
az aks create \
--name $CLUSTER_NAME \
--resource-group $RG \
--network-plugin azure \
--network-plugin-mode overlay \
--network-dataplane cilium \
--enable-acns \
--acns-advanced-networkpolicies L7

az aks get-credentials --name $CLUSTER_NAME --resource-group $RG

# Create Azure monitor resource
az resource create \
--resource-group $RG \
--namespace microsoft.monitor \
--resource-type accounts \
--name $AZURE_MONITOR_NAME \
--location $LOC \
--properties '{}'


# Create Grafana instance
az grafana create \
--name $GRAFANA_NAME \
--resource-group $RG

grafanaId=$(az grafana show --name $GRAFANA_NAME --resource-group $RG --query id --output tsv)

azuremonitorId=$(az resource show \
--resource-group $RG \
--name $AZURE_MONITOR_NAME \
--resource-type "Microsoft.Monitor/accounts" \
--query id \
--output tsv)

az aks update \
--name $CLUSTER_NAME \
--resource-group $RG \
--enable-azure-monitor-metrics \
--azure-monitor-workspace-resource-id $azuremonitorId \
--grafana-resource-id $grafanaId

wget https://raw.githubusercontent.com/Azure/prometheus-collector/refs/heads/main/otelcollector/configmaps/ama-metrics-settings-configmap.yaml

# Edit the file above to update the following
# networkobservabilityHubble = "hubble"
# also
# minimal-ingestion-profile: |-
# enabled = false

kubectl apply -f ama-metrics-settings-configmap.yaml

# Deploy a sample app
kubectl create ns pets

kubectl apply -f https://raw.githubusercontent.com/Azure-Samples/aks-store-demo/main/aks-store-all-in-one.yaml -n pets

# start the relay port-forward
kubectl port-forward -n kube-system svc/hubble-relay --address 127.0.0.1 4245:443
```

Setup hubble cli authentication


```bash
mkdir .certs
kubectl get secret hubble-relay-client-certs -n kube-system -o jsonpath='{.data.ca\.crt}'|base64 -d>$(pwd)/.certs/ca.crt
kubectl get secret hubble-relay-client-certs -n kube-system -o jsonpath='{.data.tls\.crt}'|base64 -d>$(pwd)/.certs/tls.crt
kubectl get secret hubble-relay-client-certs -n kube-system -o jsonpath='{.data.tls\.key}'|base64 -d>$(pwd)/.certs/tls.key

hubble config set tls-ca-cert-files $(pwd)/.certs/ca.crt
hubble config set tls-client-cert-file $(pwd)/.certs/tls.crt
hubble config set tls-client-key-file $(pwd)/.certs/tls.key

hubble config set tls true
hubble config set tls-server-name instance.hubble-relay.cilium.io

export GRPC_ENFORCE_ALPN_ENABLED=false

hubble observe -f 
```