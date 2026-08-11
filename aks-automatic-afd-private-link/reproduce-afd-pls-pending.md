# Reproduce AFD Private Link pending approval with AKS Automatic App Routing

This document reproduces an AKS Automatic + Azure Front Door Private Link approval issue when wildcard Private Link Service auto-approval isn't acceptable.

The AKS side works as expected: AKS Automatic's managed Application Routing Gateway API implementation can create an internal Gateway, propagate Azure Private Link Service annotations to the generated `LoadBalancer` service, and create a Private Link Service in the node resource group. The issue appears when Azure Front Door creates its private endpoint connection from an Azure Front Door service-owned subscription that doesn't match the customer's allowlisted subscription.

This guide intentionally uses HTTP between Azure Front Door and the gateway to keep the focus on Private Link approval behavior. Certificates and end-to-end TLS are not required to reproduce the issue.

## Summary of the issue

This reproduction demonstrates:

1. AKS Automatic creates the managed Gateway and Private Link Service correctly.
2. AKS Automatic node resource group lockdown blocks manual approval of pending Private Link Service connections.
3. If the Private Link Service allowlists the customer subscription, Azure Front Door still creates the private endpoint connection from an AFD service-owned subscription.
4. Because the AFD service-owned subscription isn't in `azure-pls-auto-approval`, the connection remains `Pending`.
5. Wildcard auto-approval (`"*"`) would allow the connection to approve, but that can violate customer security requirements.

The product gap is the combination of **unknown AFD service-owned private endpoint subscription ID** plus **AKS Automatic node resource group lockdown**. Without wildcard auto-approval, the customer can't reliably pre-allowlist AFD, and after the connection is created they can't manually approve it.

## What this creates

- An AKS Automatic cluster using managed Gateway API App Routing.
- A managed Istio Gateway exposed through an internal Azure Load Balancer.
- An Azure Private Link Service created automatically from Kubernetes service annotations.
- A sample app and `HTTPRoute`.
- An Azure Front Door Premium profile with an origin that requests a private endpoint connection to the AKS-created Private Link Service.

No Helm charts or self-managed ingress controllers are installed.

## Prerequisites

You need:

- Azure CLI with the `aks-preview` and `cdn` extensions if your CLI does not already include these commands.
- `kubectl`.
- Permission to create AKS, Azure Front Door, and network resources.

```bash
az extension add --name aks-preview --upgrade
az extension add --name cdn --upgrade
az account show -o table
```

Set the shared variables used throughout the walkthrough.

```bash
RG=rg-afd-aks-auto-pls
LOC=westus3
CLUSTER=aks-auto-afd-pls
K8S_VERSION=1.36.2

AFD_PROFILE=afdauto$(date +%m%d%H%M)$RANDOM
AFD_ENDPOINT=$AFD_PROFILE
AFD_ORIGIN_GROUP=og-aks
AFD_ORIGIN=origin-aks-pls

# For the reproduction, intentionally set this to the customer subscription
# that contains the AFD profile. The issue is that AFD creates the private
# endpoint request from a service-owned subscription instead, so the PLS
# connection remains Pending.
AFD_PRIVATE_ENDPOINT_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
```

## Create the AKS Automatic cluster

This walkthrough targets Kubernetes 1.36 or later because AKS Automatic uses the Application Routing Gateway API implementation as its production ingress default on 1.36+. The `--enable-gateway-api` flag installs the managed Gateway API CRDs, and `--enable-app-routing-istio` enables the managed App Routing Gateway implementation that creates the `approuting-istio` `GatewayClass`.

```bash
az group create -g $RG -l $LOC

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

Verify the managed Gateway API implementation is present.

```bash
kubectl get gatewayclass
kubectl get pods -n aks-istio-system
```

You should see a `GatewayClass` named `approuting-istio` and running `istiod` pods in `aks-istio-system`.

If you are using an existing cluster and don't see `approuting-istio`, enable the managed Gateway API CRDs and App Routing Gateway implementation explicitly:

```bash
az aks update \
  -g $RG \
  -n $CLUSTER \
  --enable-gateway-api \
  --enable-app-routing-istio

kubectl get gatewayclass
```

## Create a Gateway with Private Link annotations

The annotations below are the key to the scenario:

- `azure-load-balancer-internal` creates an internal Load Balancer.
- `azure-pls-create` creates an Azure Private Link Service for that Load Balancer.
- `azure-pls-auto-approval` allows private endpoint requests from the specified subscription to auto-approve.
- `azure-pls-visibility` makes the Private Link Service visible to the specified subscription.

For this reproduction, the annotations intentionally use the customer subscription ID. This mirrors the secure customer expectation: only private endpoint requests from the customer's own subscription should be auto-approved. Azure Front Door later creates the request from a different service-owned subscription, causing the connection to remain pending.

```bash
if [ -z "$AFD_PRIVATE_ENDPOINT_SUBSCRIPTION_ID" ]; then
  echo "Set AFD_PRIVATE_ENDPOINT_SUBSCRIPTION_ID before creating the Gateway."
  exit 1
fi

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
kubectl get gateway afd-pls-gateway
```

The managed controller creates a Deployment, Service, HPA, and PDB for the Gateway. The Service is the important resource for Azure Private Link Service creation.

```bash
kubectl get deploy,svc,hpa,pdb \
  -l gateway.networking.k8s.io/gateway-name=afd-pls-gateway

kubectl get svc afd-pls-gateway-approuting-istio -o yaml
```

Wait for the Gateway to receive an internal IP address.

```bash
kubectl wait --for=condition=Programmed gateway/afd-pls-gateway --timeout=5m

GATEWAY_IP=$(kubectl get gateway afd-pls-gateway \
  -o jsonpath='{.status.addresses[0].value}')

echo $GATEWAY_IP
```

## Deploy a test app and route

AKS Automatic applies deployment safeguards, so the sample deployment includes probes and resource requests.

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
kubectl get httproute afd-echo
```

At this point, the Gateway has a private IP. If your machine has network access to the cluster virtual network, you can test directly:

```bash
curl -i http://$GATEWAY_IP/
```

If your local machine is not connected to the VNet, skip this direct test. Azure Front Door reaches the origin through Private Link, not through your client network path.

## Find the generated Private Link Service

The Private Link Service is created in the AKS node resource group, not in the user resource group.

```bash
NODE_RG=$(az aks show -g $RG -n $CLUSTER --query nodeResourceGroup -o tsv)

PLS_NAME=$(az network private-link-service list \
  -g $NODE_RG \
  --query '[0].name' \
  -o tsv)

PLS_ID=$(az network private-link-service show \
  -g $NODE_RG \
  -n $PLS_NAME \
  --query id \
  -o tsv)

az network private-link-service show \
  -g $NODE_RG \
  -n $PLS_NAME \
  --query '{name:name,alias:alias,visibility:visibility,autoApproval:autoApproval,provisioningState:provisioningState}' \
  -o json
```

You should see `autoApproval.subscriptions` and `visibility.subscriptions` populated with the customer subscription ID from the Gateway annotations.

This matters for AKS Automatic because the node resource group is locked down. Manual approval of a Private Endpoint connection can be blocked by the node resource group deny assignment. Auto-approval avoids that manual approval path.

Avoid using `service.beta.kubernetes.io/azure-pls-auto-approval: "*"` as the production answer. It is useful for quick tests, but it can violate customer security policy because anyone who can create a private endpoint from an allowed subscription and knows the PLS resource ID could be approved automatically.

## Create Azure Front Door Premium

Create the profile, endpoint, and origin group.

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

Now create the AFD origin using the AKS-created Private Link Service.

Do not set `groupId` when the target is a `Microsoft.Network/privateLinkServices` resource. Azure Front Door rejects `groupId` for Private Link Service origins.

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

Even if you forward HTTP to the origin in this walkthrough, Azure Front Door requires certificate name check to remain enabled for Private Link origins. For a production HTTPS origin, set `--host-name` and `--origin-host-header` to the hostname that matches the certificate presented by the Gateway.

Create a route and link it to the default Front Door endpoint domain.

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

## Validate the pending connection

Check the Private Link Service connection state. For this reproduction, it is expected to remain `Pending` because the private endpoint request comes from an AFD service-owned subscription instead of the customer subscription allowlisted on the PLS.

```bash
az network private-link-service show \
  -g $NODE_RG \
  -n $PLS_NAME \
  --query '{
    autoApproval:autoApproval,
    visibility:visibility,
    connections:privateEndpointConnections[].{
      status:privateLinkServiceConnectionState.status,
      description:privateLinkServiceConnectionState.description,
      provisioningState:provisioningState
    }
  }' \
  -o json
```

Expected result:

```json
{
  "autoApproval": {
    "subscriptions": [
      "<CUSTOMER_SUBSCRIPTION_ID>"
    ]
  },
  "connections": [
    {
      "description": "Azure Front Door connection to AKS Automatic App Routing Gateway",
      "provisioningState": "Succeeded",
      "status": "Pending"
    }
  ],
  "visibility": {
    "subscriptions": [
      "<CUSTOMER_SUBSCRIPTION_ID>"
    ]
  }
}
```

You can confirm the mismatch by inspecting the private endpoint ID:

```bash
az network private-link-service show \
  -g $NODE_RG \
  -n $PLS_NAME \
  --query 'privateEndpointConnections[].privateEndpoint.id' \
  -o tsv
```

The subscription segment in that ID is the AFD service-owned subscription that created the private endpoint connection. It is not necessarily the subscription containing your Azure Front Door profile.

Wait for Azure Front Door configuration deployment and then test the default endpoint.

```bash
AFD_HOST=$(az afd endpoint show \
  -g $RG \
  --profile-name $AFD_PROFILE \
  -n $AFD_ENDPOINT \
  --query hostName \
  -o tsv)

az afd route show \
  -g $RG \
  --profile-name $AFD_PROFILE \
  --endpoint-name $AFD_ENDPOINT \
  -n route-all \
  --query '{deploymentStatus:deploymentStatus,provisioningState:provisioningState}' \
  -o json

curl -i http://$AFD_HOST/
```

If the Private Link Service connection remains `Pending`, traffic won't reach the origin through Private Link. That pending state is the expected reproduction result.

## Clean up

Delete the resource group when you are finished.

```bash
az group delete -g $RG --yes --no-wait
```

## Notes and troubleshooting

- For AKS Automatic, the node resource group uses lockdown. Manual private endpoint approval against resources in that group can be blocked by deny assignments.
- Configuring PLS auto-approval before Azure Front Door creates its private endpoint connection works only if the allowlist contains the subscription that AFD actually uses to create the private endpoint request.
- With Gateway API App Routing, use `Gateway.spec.infrastructure.annotations`; do not use `NginxIngressController` resources.
- The generated Gateway service should show the PLS annotations when you run:

  ```bash
  kubectl get svc afd-pls-gateway-approuting-istio -o yaml
  ```

- The Private Link Service should show `autoApproval` and `visibility` values matching your annotations.
- The subscription that contains the Azure Front Door profile may not be the subscription that creates the private endpoint connection.
- If you replace the customer subscription with the discovered AFD service-owned subscription and recreate the Gateway/PLS before creating the AFD origin, the connection can auto-approve. That is useful for diagnosis, but it does not remove the customer concern unless those service-owned subscription IDs are documented and acceptable to the customer's security policy.
- This walkthrough uses only managed AKS/App Routing components. Do not install ingress-nginx, Istio Helm charts, or external gateway controllers for this scenario.
