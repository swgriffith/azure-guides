resource "azurerm_kubernetes_cluster" "aks" {
  name                = var.cluster_name
  location            = azurerm_resource_group.aks.location
  resource_group_name = azurerm_resource_group.aks.name
  dns_prefix = var.cluster_name
  
  default_node_pool {
    name       = "default"
    node_count = 1
    vm_size    = "Standard_D2_v2"
    vnet_subnet_id = azurerm_subnet.aks.id
  }

  identity {
    type = "UserAssigned"
    identity_ids = ["${azurerm_user_assigned_identity.aks.id}"]
  }

  oms_agent {
      log_analytics_workspace_id = azurerm_log_analytics_workspace.aks.id
  }

  depends_on = [
    azurerm_user_assigned_identity.aks
  ]

}
