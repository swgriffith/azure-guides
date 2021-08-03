resource userAssignedMI 'Microsoft.ManagedIdentity/userAssignedIdentities@2018-11-30' = {
  name: 'deploymentMgrManagedIdentity'
  location: resourceGroup().location
}

output userAssignedMIID string = userAssignedMI.id
output userAssignedMIAppprincipalId string = userAssignedMI.properties.principalId
