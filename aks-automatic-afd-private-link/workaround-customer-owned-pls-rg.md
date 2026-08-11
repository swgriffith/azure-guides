# Work around AFD Private Link approval by creating the AKS PLS in a customer-owned resource group

This guide shows a practical workaround for the AKS Automatic + Azure Front Door Private Link approval issue.

Instead of letting AKS create the Private Link Service (PLS) in the locked AKS node resource group, configure the managed Gateway to create the PLS in a customer-owned resource group using:

```yaml
service.beta.kubernetes.io/azure-pls-resource-group: "<customer-owned-resource-group>"
```

This keeps the managed AKS/App Routing Gateway path, avoids installing extra controllers or Helm charts, and gives the customer control over the Private Link Service approval workflow.

## Why this works

AKS Automatic node resource groups are locked down. If an Azure Front Door private endpoint connection remains `Pending`, manual approval against a PLS in the node resource group can be blocked by the deny assignment.

Moving the PLS to a customer-owned resource group changes the control point:

- AKS still creates and owns the Kubernetes Gateway and Load Balancer service.
- Azure cloud provider still creates the PLS automatically.
- The PLS is created in a resource group where the customer can manage permissions and approval.
- If auto-approval does not match the AFD service-owned subscription, the customer can approve the private endpoint connection manually or update the PLS allowlist and recreate the AFD origin.

## Prerequisites

You need:

- Azure CLI with the `aks-preview` and `cdn` extensions if your CLI does not already include these commands.
- `kubectl`.
- Permission to create AKS, Azure Front Door, managed identities, role assignments, and network resources.

```bash
az extension add --name aks-preview --upgrade
az extension add --name cdn --upgrade
az account show -o table
```

Set variables for the lab.

```bash
RG=rg-afd-aks-auto-pls-workaround
PLS_RG=rg-afd-aks-auto-pls-workaround-pls
LOC=westus3
CLUSTER=aks-auto-afd-pls
K8S_VERSION=1.36.2

AFD_PROFILE=afdauto$(date +%m%d%H%M)$RANDOM
AFD_ENDPOINT=$AFD_PROFILE
AFD_ORIGIN_GROUP=og-aks
AFD_ORIGIN=origin-aks-pls

# Start with the customer subscription. If AFD creates the private endpoint
# from a service-owned subscription, the connection may still be Pending, but
# the PLS will be in a resource group where you can approve or update it.
AFD_PRIVATE_ENDPOINT_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
```

## Create resource groups

Use one resource group for AKS and AFD, and a second customer-owned resource group for the PLS.

```bash
az group create -g $RG -l $LOC
az group create -g $PLS_RG -l $LOC
```

## Create AKS Automatic with App Routing Gateway API

The lab targets Kubernetes 1.36 or later. `--enable-gateway-api` installs the managed Gateway API CRDs, and `--enable-app-routing-istio` enables the managed App Routing Gateway implementation.

```bash
az aks create \
  -g $RG \
  -n $CLUSTER \
  -l $LOC \
  --kubernetes-version $K8S_VERSION \
  --sku automatic \
  --enable-gateway-api \
  --enable-app-routing-istio \
  --no-ssh-key

az aks get-credentials -g $RG -n $CLUSTER --overwrite-existing
```

Verify the managed GatewayClass exists.

```bash
kubectl get gatewayclass
kubectl get pods -n aks-istio-system
```

You should see `GatewayClass/approuting-istio`.

## Grant AKS permission to create the PLS in the customer-owned resource group

The Azure cloud provider running for the cluster needs permission to create and update the Private Link Service in `$PLS_RG`.

```bash
AKS_PRINCIPAL_ID=$(az aks show \
  -g $RG \
  -n $CLUSTER \
  --query identity.principalId \
  -o tsv)

PLS_RG_ID=$(az group show \
  -g $PLS_RG \
  --query id \
  -o tsv)

az role assignment create \
  --assignee $AKS_PRINCIPAL_ID \
  --role "Network Contributor" \
  --scope $PLS_RG_ID
```

Role assignment propagation can take a few minutes. If PLS creation fails with authorization errors, wait and reapply the Gateway after propagation completes.

## Create the Gateway and tell AKS where to place the PLS

The important annotation is `service.beta.kubernetes.io/azure-pls-resource-group: "${PLS_RG}"`.

```bash
cat <<EOF | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: afd-pls-gateway
  namespace: default
spec:
  gatewayClassName: approuting-istio
  infrastructure:
    annotations:
      service.beta.kubernetes.io/azure-load-balancer-internal: "true"
      service.beta.kubernetes.io/azure-pls-create: "true"
      service.beta.kubernetes.io/azure-pls-resource-group: "${PLS_RG}"
      service.beta.kubernetes.io/azure-pls-auto-approval: "${AFD_PRIVATE_ENDPOINT_SUBSCRIPTION_ID}"
      service.beta.kubernetes.io/azure-pls-visibility: "${AFD_PRIVATE_ENDPOINT_SUBSCRIPTION_ID}"
  listeners:
  - name: http
    port: 80
    protocol: HTTP
    allowedRoutes:
      namespaces:
        from: Same
EOF

kubectl wait --for=condition=Accepted gateway/afd-pls-gateway --timeout=120s
kubectl wait --for=condition=Programmed gateway/afd-pls-gateway --timeout=5m
```

Confirm the generated service has the expected annotations.

```bash
kubectl get svc afd-pls-gateway-approuting-istio -o yaml
```

## Deploy a sample app and route

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: afd-echo
  namespace: default
spec:
  replicas: 2
  selector:
    matchLabels:
      app: afd-echo
  template:
    metadata:
      labels:
        app: afd-echo
    spec:
      containers:
      - name: echo
        image: mcr.microsoft.com/azuredocs/aks-helloworld:v1
        ports:
        - containerPort: 80
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 500m
            memory: 512Mi
        readinessProbe:
          httpGet:
            path: /
            port: 80
          initialDelaySeconds: 5
          periodSeconds: 10
        livenessProbe:
          httpGet:
            path: /
            port: 80
          initialDelaySeconds: 15
          periodSeconds: 20
---
apiVersion: v1
kind: Service
metadata:
  name: afd-echo
  namespace: default
spec:
  selector:
    app: afd-echo
  ports:
  - port: 80
    targetPort: 80
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: afd-echo
  namespace: default
spec:
  parentRefs:
  - name: afd-pls-gateway
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: afd-echo
      port: 80
EOF

kubectl rollout status deploy/afd-echo --timeout=5m
kubectl wait --for=condition=Accepted httproute/afd-echo --timeout=120s
```

## Find the PLS in the customer-owned resource group

```bash
PLS_NAME=$(az network private-link-service list \
  -g $PLS_RG \
  --query '[0].name' \
  -o tsv)

PLS_ID=$(az network private-link-service show \
  -g $PLS_RG \
  -n $PLS_NAME \
  --query id \
  -o tsv)

az network private-link-service show \
  -g $PLS_RG \
  -n $PLS_NAME \
  --query '{name:name,autoApproval:autoApproval,visibility:visibility,provisioningState:provisioningState}' \
  -o json
```

The PLS should be in `$PLS_RG`, not the AKS node resource group.

## Create Azure Front Door Premium

```bash
az afd profile create \
  -g $RG \
  -n $AFD_PROFILE \
  --sku Premium_AzureFrontDoor

az afd endpoint create \
  -g $RG \
  --profile-name $AFD_PROFILE \
  -n $AFD_ENDPOINT \
  --enabled-state Enabled

az afd origin-group create \
  -g $RG \
  --profile-name $AFD_PROFILE \
  -n $AFD_ORIGIN_GROUP \
  --probe-path / \
  --probe-protocol Http \
  --probe-request-type GET \
  --probe-interval-in-seconds 60 \
  --sample-size 4 \
  --successful-samples-required 3 \
  --additional-latency-in-milliseconds 50
```

Create the origin using the customer-owned PLS.

Do not set `groupId` for a `Microsoft.Network/privateLinkServices` target.

```bash
cat > /tmp/afd-shared-pls.json <<EOF
{
  "privateLink": {
    "id": "$PLS_ID"
  },
  "privateLinkLocation": "$LOC",
  "requestMessage": "Azure Front Door connection to AKS Automatic App Routing Gateway"
}
EOF

az afd origin create \
  -g $RG \
  --profile-name $AFD_PROFILE \
  --origin-group-name $AFD_ORIGIN_GROUP \
  -n $AFD_ORIGIN \
  --host-name "afd-pls-gateway.local" \
  --origin-host-header "afd-pls-gateway.local" \
  --http-port 80 \
  --https-port 443 \
  --enabled-state Enabled \
  --enforce-certificate-name-check true \
  --shared-private-link-resource @/tmp/afd-shared-pls.json
```

Create a route.

```bash
az afd route create \
  -g $RG \
  --profile-name $AFD_PROFILE \
  --endpoint-name $AFD_ENDPOINT \
  -n route-all \
  --origin-group $AFD_ORIGIN_GROUP \
  --supported-protocols Http \
  --patterns-to-match '/*' \
  --forwarding-protocol HttpOnly \
  --link-to-default-domain Enabled \
  --https-redirect Disabled \
  --enabled-state Enabled
```

## If the connection is pending, approve it or update the allowlist

Check the connection.

```bash
az network private-link-service show \
  -g $PLS_RG \
  -n $PLS_NAME \
  --query 'privateEndpointConnections[].{
    name:name,
    status:privateLinkServiceConnectionState.status,
    description:privateLinkServiceConnectionState.description,
    privateEndpointId:privateEndpoint.id
  }' \
  -o json
```

If the connection is `Pending`, the private endpoint request likely came from an AFD service-owned subscription that was not in the PLS allowlist. Because the PLS is in a customer-owned resource group, you have two options.

Option 1: approve the pending connection manually.

```bash
CONNECTION_NAME=$(az network private-link-service show \
  -g $PLS_RG \
  -n $PLS_NAME \
  --query 'privateEndpointConnections[0].name' \
  -o tsv)

az network private-endpoint-connection approve \
  -g $PLS_RG \
  --name $CONNECTION_NAME \
  --resource-name $PLS_NAME \
  --type Microsoft.Network/privateLinkServices \
  --description "Approved for Azure Front Door"
```

After manual approval, update the AFD origin so its `sharedPrivateLinkResource.status` records the approved state. In testing, the PLS side showed `Approved`, but the AFD origin still had `sharedPrivateLinkResource.status: null` and the AFD route remained `NotStarted` until the origin was updated.

```bash
cat > /tmp/afd-shared-pls-approved.json <<EOF
{
  "privateLink": {
    "id": "$PLS_ID"
  },
  "privateLinkLocation": "$LOC",
  "requestMessage": "Azure Front Door connection to AKS Automatic App Routing Gateway",
  "status": "Approved"
}
EOF

az afd origin update \
  -g $RG \
  --profile-name $AFD_PROFILE \
  --origin-group-name $AFD_ORIGIN_GROUP \
  -n $AFD_ORIGIN \
  --shared-private-link-resource @/tmp/afd-shared-pls-approved.json
```

Option 2: discover the AFD service-owned subscription, update the PLS allowlist, and recreate the AFD origin so the request is evaluated again.

```bash
AFD_SERVICE_SUBSCRIPTION_ID=$(az network private-link-service show \
  -g $PLS_RG \
  -n $PLS_NAME \
  --query 'privateEndpointConnections[0].privateEndpoint.id' \
  -o tsv | cut -d/ -f3)

az network private-link-service update \
  -g $PLS_RG \
  -n $PLS_NAME \
  --visibility $AFD_SERVICE_SUBSCRIPTION_ID \
  --auto-approval $AFD_SERVICE_SUBSCRIPTION_ID
```

Updating the PLS allowlist does not appear to retroactively approve an existing pending AFD connection. Recreate the AFD origin or shared private link association after updating the allowlist.

## Validate Front Door

```bash
AFD_HOST=$(az afd endpoint show \
  -g $RG \
  --profile-name $AFD_PROFILE \
  -n $AFD_ENDPOINT \
  --query hostName \
  -o tsv)

curl -i http://$AFD_HOST/
```

If the response is the AKS welcome page, the full path is working through Azure Front Door, Private Link, the managed Gateway, and the backend service.

You may still see `deploymentStatus: NotStarted` on some AFD resources even after traffic works. Confirm with response headers/body and Gateway access logs:

```bash
curl -sS -D - -o /tmp/afd-body.html http://$AFD_HOST/ | grep -iE 'HTTP/|x-cache|x-azure-ref'
head /tmp/afd-body.html

kubectl logs deploy/afd-pls-gateway-approuting-istio --tail=20
```

If you see an AFD `CONFIG_NOCACHE` 404 and no Gateway logs, wait for Front Door route propagation and confirm the route is linked to the default endpoint domain. If the PLS connection was manually approved, also confirm the AFD origin has `sharedPrivateLinkResource.status: Approved`.

## Clean up

```bash
az group delete -g $RG --yes --no-wait
az group delete -g $PLS_RG --yes --no-wait
```
