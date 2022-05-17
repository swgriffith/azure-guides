variable "resource_group_name" {
  description = "Azure Resource Group Name"
  type        = string
  default     = "aksTerraformDemo"
}

variable "location" {
    description = "Azure Deployment Region"
    type = string
    default = "eastus"
}

variable "cluster_name" {
    description = "AKS Cluster Name"
    type = string
    default = "tftestcluster"
}

variable "log_analytics_workspace_name" {
    description = "Log Analytics Workspace Name"
    type = string
    default = "grifflaspace"
}

