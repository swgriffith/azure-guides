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

resource "random_pet" "azurerm_kubernetes_nodepool_name" {
  separator = ""
  length = 1
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
    node_count = 1
  }

  azure_policy_enabled = true
}

data "local_file" "hostname_constraint_file" {
  filename = "./hostname-constraint.yml"
}


resource "azurerm_policy_definition" "hostname_policy" {
  name         = "hostnameConstraintPolicy"
  policy_type  = "Custom"
  mode         = "Microsoft.Kubernetes.Data"
  display_name = "Hostname Constraint Policy"
  description = "limit hostnames to *.demoapp.com naming convention"

  metadata = <<METADATA
    {
      "version": "1.0.0",
      "category": "Kubernetes"
    }
METADATA

  parameters = <<PARAMETERS
{
  "effect": {
    "type": "String",
    "metadata": {
      "displayName": "Effect",
      "description": "A custom policy defined in Rego rendered in base64 encoding."
    },
    "allowedValues": [
      "audit",
      "deny",
      "disabled"
    ],
    "defaultValue": "deny"
  },
  "excludedNamespaces": {
      "type": "Array",
      "metadata": {
          "displayName": "Namespace exclusions",
          "description": "List of Kubernetes namespaces to exclude from policy evaluation. Providing a value for this parameter is optional."
      },
      "defaultValue": [
          "kube-system",
          "gatekeeper-system",
          "azure-arc"
      ]
  }  
}
PARAMETERS

  policy_rule = <<POLICY_RULE
{
  "if": {
    "field": "type",
    "in": [
      "AKS Engine",
      "Microsoft.Kubernetes/connectedClusters",
      "Microsoft.ContainerService/managedClusters"
    ]
  },
  "then": {
    "effect": "[parameters('effect')]",
    "details": {
      "templateInfo": {
        "sourceType": "Base64Encoded",
        "content": "${data.local_file.hostname_constraint_file.content_base64}"
      },
      "excludedNamespaces": "[parameters('excludedNamespaces')]",
      "apiGroups": [
          "extensions", 
          "networking.k8s.io"
      ],
      "kinds": [
          "Ingress"
      ]
    }
  }
}
POLICY_RULE
}


resource "azurerm_resource_group_policy_assignment" "hostname_constraint_assignment" {
  name                 = "hostname-constraint"
  resource_group_id    = azurerm_resource_group.rg.id
  policy_definition_id = azurerm_policy_definition.hostname_policy.id
}


