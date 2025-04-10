@description('The name of the Managed Cluster resource.')
param clusterName string = 'aks101cluster'

@description('The location of the Managed Cluster resource.')
param location string = resourceGroup().location

@description('The number of nodes for the system pool.')
@minValue(1)
@maxValue(50)
param syspoolNodeCount int = 3

@description('The name of the user pool.')
param userPoolName string = 'user'

@description('The number of nodes for the user pool.')
param userPoolCount int = 3

@description('The size of the syspool Virtual Machine.')
param userPoolVMSize string = 'standard_d2s_v3'

@description('The size of the syspool Virtual Machine.')
param systemPoolVMSize string = 'standard_d2s_v3'

param serviceCidr string = '10.100.0.0/16'
param dnsServivceIP string = '10.100.0.10'
param podCidr string = '10.244.0.0/16'

@description('The SSH key to use for the cluster.')
param sshKey string = ''
param linuxAdminUser string = 'azureuser'

resource aks 'Microsoft.ContainerService/managedClusters@2024-05-01' = {
  name: clusterName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    dnsPrefix: clusterName
    agentPoolProfiles: [
      {
        name: 'sys'
        count: syspoolNodeCount
        vmSize: systemPoolVMSize
        osType: 'Linux'
        mode: 'System'
        nodeTaints: [
          'CriticalAddonsOnly=true:NoSchedule'
        ]      }
      {
        name: userPoolName
        count: userPoolCount
        vmSize: userPoolVMSize
        osType: 'Linux'
        mode: 'User'
      }
    ]
    networkProfile: {
      networkPlugin: 'azure'
      networkPluginMode: 'overlay'
      podCidr: podCidr
      serviceCidr: serviceCidr
      dnsServiceIP: dnsServivceIP
    }
    linuxProfile: {
      adminUsername: linuxAdminUser
      ssh: {
        publicKeys: [
          {
            keyData: sshKey
          }
        ]
      }
    }
  }
}


output controlPlaneFQDN string = aks.properties.fqdn
