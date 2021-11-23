param containerappName string
param environment_name string
param location string
param log_analytics_name string

resource la_workspace 'Microsoft.OperationalInsights/workspaces@2020-03-01-preview' = {
  name: log_analytics_name
  location: location
  properties: any({
    retentionInDays: 30
    features: {
      searchVersion: 1
    }
    sku: {
      name: 'PerGB2018'
    }
  })
}


resource env 'Microsoft.Web/kubeEnvironments@2021-02-01' = {
  name: environment_name
  location: location
  properties: {
    type: 'managed'
    internalLoadBalancerEnabled: false
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: la_workspace.properties.customerId
        sharedKey: la_workspace.listKeys().primarySharedKey
      }
    }
  }
}

resource containerApp 'Microsoft.Web/containerApps@2021-03-01' = {
  name: containerappName
  kind: 'containerapp'
  location: location
  properties: {
    kubeEnvironmentId: env.id
    configuration: {
      secrets: []      
      registries: []
      ingress: {
        external: true
        targetPort: 80
      }
      activeRevisionsMode: 'multiple'
    }
    template: {
      containers: [
        {
          image: 'stevegriffith/appb'
          name: 'testapp'
          env: []
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 10
        rules: [
          {
            name: 'httpscalingrule'
              http: {
                metadata: {
                  concurrentRequests: '100'
                }
              }
          }
      ]
      }
    }
  }
}
