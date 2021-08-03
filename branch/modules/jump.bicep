param subnetId string

//param count int = 1
@allowed([
  'Standard_D2s_v3'
  'Standard_D4s_v3'
])
param vmSize string = 'Standard_D4s_v3'
param adminUsername string = 'retroadmin'
param adminPublicKey string
param managedIdentity string
var customData = base64('''
#cloud-config
package_upgrade: true
runcmd:
  # Install kubectl
  - curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
  - sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
  # Install helm
  - curl https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | bash
  # Install Azure CLI
  - curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
  # Create init done file
  - touch /tmp/cloud-init-done
''')

param diskSizeGB int = 50

param name string

resource pubip 'Microsoft.Network/publicIPAddresses@2021-02-01' = {
  name: 'jump-pub-ip'
  location: resourceGroup().location
  properties: {
   publicIPAllocationMethod: 'Static'
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2020-07-01' = {
  name: '${name}-nic'
  location: resourceGroup().location
  properties: {
    ipConfigurations: [
      {
        name: 'primaryConfig'
        properties: {
          subnet: {
            id: subnetId
          }
          primary:true
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: {
            id: pubip.id
          }
        }
      }
    ]
  }
}

resource jump 'Microsoft.Compute/virtualMachines@2020-12-01' = {
  name: '${name}-vm'
  location: resourceGroup().location
  identity: {
     type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedIdentity}':{}
    }
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: name
      adminUsername: adminUsername
      customData: customData
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: adminPublicKey
            }
          ]
        }
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: 'UbuntuServer'
        sku: '18.04-LTS'
        version: 'latest'
      }
      osDisk: {
        osType: 'Linux'
        createOption: 'FromImage'
        diskSizeGB: diskSizeGB
        managedDisk: {
          storageAccountType: 'Standard_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
  }
}

// Outputs
output jumpPublicIP string = pubip.properties.ipAddress
output jumpVMName string = jump.name
