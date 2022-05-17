resource "azurerm_user_assigned_identity" "aks" {
  resource_group_name = azurerm_resource_group.aks.name
  location            = azurerm_resource_group.aks.location

  name = "cluster-mgmnt-user"
}

resource "azurerm_role_definition" "aks" {
  name        = "aks-log-analytics-user-role"
  scope       = azurerm_log_analytics_workspace.aks.id
  description = "Required permissions for Container Insights"
  role_definition_id = "341439a5-2c7b-429b-977f-f0aec2ee8ff6"

  permissions {
    actions     = [
        "Microsoft.OperationalInsights/workspaces/sharedkeys/read",
        "Microsoft.OperationalInsights/workspaces/read",
        "Microsoft.OperationsManagement/solutions/write",
        "Microsoft.OperationsManagement/solutions/read",
        "Microsoft.ManagedIdentity/userAssignedIdentities/assign/action"
        ]
    not_actions = []
  }
}

data "azurerm_user_assigned_identity" "omsagent" {
  name                = "omsagent-${azurerm_kubernetes_cluster.aks.name}"
  resource_group_name = azurerm_kubernetes_cluster.aks.node_resource_group
}

resource "azurerm_role_assignment" "aks" {
  scope                = azurerm_log_analytics_workspace.aks.id
  role_definition_id   = azurerm_role_definition.aks.role_definition_resource_id
  principal_id         = data.azurerm_user_assigned_identity.omsagent.principal_id

  depends_on = [
    azurerm_kubernetes_cluster.aks
  ]
}