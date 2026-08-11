# AKS Automatic App Routing, Azure Front Door, and Private Link

This folder contains two related guides for AKS Automatic, managed Application Routing Gateway API, Azure Private Link Service, and Azure Front Door Premium.

The core issue is that AKS Automatic locks down the node resource group. AKS can create a Private Link Service (PLS) for a managed Gateway, but if Azure Front Door creates a private endpoint connection that is not auto-approved, the customer may not be able to approve it manually because the PLS is in the locked node resource group.

## Guides

| File | Purpose |
|---|---|
| [reproduce-afd-pls-pending.md](reproduce-afd-pls-pending.md) | Reproduces the customer issue. The PLS is created in the AKS node resource group and allowlists the customer subscription. Azure Front Door creates the private endpoint from a service-owned subscription, so the connection remains `Pending`. |
| [workaround-customer-owned-pls-rg.md](workaround-customer-owned-pls-rg.md) | Shows the workaround. The Gateway tells AKS to create the PLS in a customer-owned resource group using `service.beta.kubernetes.io/azure-pls-resource-group`, so the customer can manage approval even if auto-approval does not match. |

## Summary

The managed Gateway API path itself works:

1. AKS Automatic creates the managed Gateway infrastructure.
2. `Gateway.spec.infrastructure.annotations` are propagated to the generated `LoadBalancer` service.
3. The Azure cloud provider creates a Private Link Service for the internal Load Balancer.
4. Azure Front Door Premium can create a private endpoint connection to that PLS.

The problem is approval:

- Wildcard auto-approval (`"*"`) can make the connection approve automatically, but may not be acceptable for regulated customers.
- Allowlisting only the customer subscription can leave the AFD connection `Pending`, because AFD may create the private endpoint from an AFD service-owned subscription.
- Manual approval can be blocked when the PLS lives in the AKS Automatic locked node resource group.

The preferred workaround is to create the PLS in a customer-owned resource group and grant the AKS cluster identity permission to manage PLS resources there.

