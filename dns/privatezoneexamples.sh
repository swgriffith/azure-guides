#!/bin/sh

# Default Private Cluster Setup
az aks create -g EphAKSPrivateDNSDemo \
-n aksspokea \
--enable-private-cluster \
--enable-managed-identity \
--assign-identity /subscriptions/<SUBID>/resourceGroups/EphAKSPrivateDNSDemo/providers/Microsoft.ManagedIdentity/userAssignedIdentities/AKSClusterManagedIdentity \
--vnet-subnet-id /subscriptions/<SUBID>/resourceGroups/EphAKSPrivateDNSDemo/providers/Microsoft.Network/virtualNetworks/vnet-spoke-a/subnets/cluster-subnet \
-c 1



# Private Cluster with BYO Private Zone
az aks create -g EphAKSPrivateDNSDemo \
-n aksspokeb \
--enable-private-cluster \
--private-dns-zone /subscriptions/<SUBID>/resourceGroups/ephaksprivatednsdemo/providers/Microsoft.Network/privateDnsZones/privatelink.eastus.azmk8s.io \
--enable-managed-identity \
--assign-identity /subscriptions/<SUBID>/resourceGroups/EphAKSPrivateDNSDemo/providers/Microsoft.ManagedIdentity/userAssignedIdentities/AKSClusterManagedIdentity \
--vnet-subnet-id /subscriptions/<SUBID>/resourceGroups/EphAKSPrivateDNSDemo/providers/Microsoft.Network/virtualNetworks/vnet-spoke-b/subnets/cluster-subnet \
-c 1



# Private Cluster with BYO DNS
az aks create -g EphAKSPrivateDNSDemo \
-n aksspokec \
--enable-private-cluster \
--private-dns-zone None \
--enable-managed-identity \
--assign-identity /subscriptions/<SUBID>/resourceGroups/EphAKSPrivateDNSDemo/providers/Microsoft.ManagedIdentity/userAssignedIdentities/AKSClusterManagedIdentity \
--vnet-subnet-id /subscriptions/<SUBID>/resourceGroups/EphAKSPrivateDNSDemo/providers/Microsoft.Network/virtualNetworks/vnet-spoke-c/subnets/cluster-subnet \
-c 1

