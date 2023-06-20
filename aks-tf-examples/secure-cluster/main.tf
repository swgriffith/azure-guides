# Generate random resource group name
resource "random_pet" "rg_name" {
  prefix = var.resource_group_name_prefix
}

resource "azurerm_resource_group" "rg" {
  location = var.resource_group_location
  name     = random_pet.rg_name.id
}

resource "random_pet" "azurerm_kubernetes_cluster_name" {
  prefix = "cluster"
}

resource "random_pet" "azurerm_kubernetes_cluster_dns_prefix" {
  prefix = "dns"
}

resource "azurerm_kubernetes_cluster" "k8s" {
  location            = azurerm_resource_group.rg.location
  name                = random_pet.azurerm_kubernetes_cluster_name.id
  resource_group_name = azurerm_resource_group.rg.name
  dns_prefix          = random_pet.azurerm_kubernetes_cluster_dns_prefix.id

  identity {
    type = "SystemAssigned"
  }

  default_node_pool {
    name       = "agentpool"
    vm_size    = "Standard_D2_v2"
    node_count = var.node_count
    vnet_subnet_id = var.vnet_subnet_id    
  }

  private_cluster_enabled = true

  network_profile {
    network_plugin      = var.network_profile.network_plugin
    network_plugin_mode = var.network_profile.network_plugin_mode
    network_policy      = var.network_profile.network_policy
    load_balancer_sku   = var.network_profile.load_balancer_sku
    outbound_type       = var.network_profile.outbound_type
    service_cidr        = var.network_profile.service_cidr
    service_cidrs       = var.network_profile.service_cidrs
    dns_service_ip      = var.network_profile.dns_service_ip
    pod_cidr            = var.network_profile.pod_cidr
    pod_cidrs           = var.network_profile.pod_cidrs
    ip_versions         = var.network_profile.ip_versions
    ebpf_data_plane     = var.network_profile.ebpf_data_plane
  }
}