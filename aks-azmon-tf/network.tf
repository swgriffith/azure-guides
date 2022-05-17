## Create the virtual network for an AKS cluster
resource "azurerm_virtual_network" "aks" {
  name                = "aksvnet"
  location            = azurerm_resource_group.aks.location
  resource_group_name = azurerm_resource_group.aks.name
  address_space       = ["10.100.0.0/16"]
}

resource "azurerm_subnet" "aks" {
  name                 = "akssubnet"
  resource_group_name  = azurerm_resource_group.aks.name
  virtual_network_name = azurerm_virtual_network.aks.name
  address_prefixes = ["10.100.0.0/24"]
}