param armDeploymentName string
param subscriptionId string
param tenantId string
param userAssignedMIID string
param k3sToken string
param adminUserName string
param sshKeyPath string

var script = '''
echo "Cloning the deployment repository"
git clone https://github.com/swgriffith/azure-guides.git
cd ./azure-guides/branch/scripts

ls

echo "Starting deployment script"
#./run.sh bicep

#json="{\"data\":{\"param1\":\"$1\",\"param2\":\"$2\"}}"

echo "$json" > $AZ_SCRIPTS_OUTPUT_PATH
'''

resource bashtest 'Microsoft.Resources/deploymentScripts@2020-10-01' = {
  name: 'runBashWithOutputs'
  location: resourceGroup().location
  kind: 'AzureCLI'
  identity: {
    type: 'UserAssigned'
   userAssignedIdentities: {
     '${userAssignedMIID}':{}
   }
 }
  properties: {
    azCliVersion: '2.26.1' 
    retentionInterval: 'P1D'
    cleanupPreference: 'OnSuccess'
    scriptContent: script
    environmentVariables:[
      {
        name: 'ARM_DEPLOYMENT_NAME'
        value:armDeploymentName
      }
      {
        name: 'SUBSCRIPTION_ID'
        value:subscriptionId
      }
      {
        name: 'TENANT_ID'
        value:tenantId
      }
      {
        name: 'K3S_TOKEN'
        value:k3sToken
      }
      {
        name: 'ADMIN_USER_NAME'
        value:adminUserName
      }
      {
        name: 'SSH_KEY_PATH'
        value:sshKeyPath
      }
    ] 
  }
}
