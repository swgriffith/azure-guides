param prefix string
param count int = 2

param subnetId string
//param loadBalancerBackendAddressPools array

param vmSize string = 'Standard_D4s_v3'
param adminUsername string
param adminPublicKey string
//param customData string
param diskSizeGB int = 50

//param mastersFQDN string

param name string
param control string

param k3sToken string
var customData = base64(format('''
#cloud-config
package_upgrade: true
runcmd:
  - curl -sfL https://get.k3s.io | K3S_URL=https://{0}:6443 K3S_TOKEN={1} sh -s -
''',control,k3sToken))

resource workers 'Microsoft.Compute/virtualMachineScaleSets@2021-03-01' = {
  name: '${name}-vmss'
  location: resourceGroup().location
  sku: {
    name:vmSize
    capacity: count
  }
  properties: {
    upgradePolicy: {
       mode: 'Manual'
    }
    virtualMachineProfile: {
      osProfile: {
        computerNamePrefix: name
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
        networkInterfaceConfigurations: [
          {
            name: '${prefix}-nic'
            properties: {
              primary: true
              ipConfigurations:[
                {
                  name: '${prefix}-nic-priv-ip'
                  properties: {
                    subnet: {
                      id: subnetId
                    }
                  }
                }
              ]
            }
          }
        ]
      }
    }     
   }
  
}
