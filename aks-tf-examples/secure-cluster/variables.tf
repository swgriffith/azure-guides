variable "resource_group_location" {
  type        = string
  default     = "eastus"
  description = "Location of the resource group."
}

variable "resource_group_name_prefix" {
  type        = string
  default     = "rg"
  description = "Prefix of the resource group name that's combined with a random ID so name is unique in your Azure subscription."
}

variable "node_count" {
  type        = number
  description = "The initial quantity of nodes for the node pool."
  default     = 3
}

variable "vnet_subnet_id" {
    type = string
    default = "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/RedDogAKSWorkshop/providers/Microsoft.Network/virtualNetworks/reddog-vnet/subnets/aks"
  
}

variable "network_profile" {
  description = <<EOT
  (Optional) The network profile block for the Kubernetes cluster.
  If not specified, the network profile will be of type Azure.
  EOT
  type = object({
    network_plugin      = string
    network_plugin_mode = optional(string)
    network_policy      = optional(string)
    load_balancer_sku   = optional(string)
    outbound_type       = optional(string)
    service_cidr        = optional(string)
    service_cidrs       = optional(list(string))
    dns_service_ip      = optional(string)
    pod_cidr            = optional(string)
    pod_cidrs           = optional(list(string))
    ip_versions         = optional(list(string))
    ebpf_data_plane     = optional(string)
  })
  default = {
    network_plugin      = "azure"
    network_plugin_mode = "Overlay"
    network_policy      = "calico"
    outbound_type = "userDefinedRouting"
  }
}

variable "msi_id" {
  type        = string
  description = "The Managed Service Identity ID. Set this value if you're running this example using Managed Identity as the authentication method."
  default     = null
}