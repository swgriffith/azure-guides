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

  linux_profile {
    admin_username = "griffith"
    ssh_key {
      key_data = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDOwu58feXMhtUUfUv+dmvWzvsi3GQuatetmLEohqUbOy9L1aW5rzb1k5Axoj0tfP+DNzDTtMO40RBFNdRFlsBjutl0QYh+3UqQjFRjdrG1VRtpjZPBEvAsJ8YmNjVpHRVhnMV0FjiMkDqI9vJk0ScypMDuHvmhZ/pV4cgNeCQ6uFPYKT+WqbZ5rQ/1ex1aRemydIAdoQDXl6zLbqAkziBGDvaEyAitY44jVTsCjpo/EVf9L+sk4aNx9AxqeR2ZgZflwiWK5oZKAFYpC+Nb+27KNE4du17U5Gjh3VmqG1i2prkhvGaDZiZHeWM0vubpgHqftmEO8HZPGMO/FrSh4R+LomRvHNp3wYo835wXzQSgzVFX1+Xm/SDyL6aYro023Cw88K+SaEKgGFrIxbuyVI0NRj010MKGj2RlixD81IDbzE+pm9yMcTFWMHqBk8JX1I76IzKzjBnyRUxytMUVq+5CR6S/LQpf2xZwbiu0TMwv0ctEsmogAKsdq9hPhmBBakc= griffith@Steves-MacBook-Pro.local"
    }
  }
}