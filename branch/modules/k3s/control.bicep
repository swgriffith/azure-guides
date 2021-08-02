param subnetId string

@allowed([
  'Standard_D2s_v3'
  'Standard_D4s_v3'
])
param vmSize string = 'Standard_D4s_v3'
param adminUsername string = 'retroadmin'
param adminPublicKey string
param diskSizeGB int = 50
param k3sToken string

var customData = base64(format('''
#cloud-config
package_upgrade: true
runcmd:
  - curl -sfL https://get.k3s.io | K3S_TOKEN={0} sh -s -
''',k3sToken))

param name string

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
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}

resource masters 'Microsoft.Compute/virtualMachines@2020-12-01' = {
  name: '${name}-vm'
  location: resourceGroup().location
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

