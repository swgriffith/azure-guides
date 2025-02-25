data "azuread_client_config" "current" {}

resource "azuread_application" "entra-app" {
  display_name = "flexible-fic"
  owners       = [data.azuread_client_config.current.object_id]
}

resource "azuread_service_principal" "entra-sp" {
  client_id                    = azuread_application.entra-app.client_id
  app_role_assignment_required = false
  owners                       = [data.azuread_client_config.current.object_id]
}

locals {
  flexible_fic = {
    name = azuread_application.entra-app.display_name
    description = "Federated Identity credential for Git to perform Project Operations"
    issuer = "https://token.actions.githubusercontent.com"
    audiences = ["api://AzureADTokenExchange"]
    subject = null
    claimsMatchingExpression = {
      value = "claims['sub'] matches 'repo:contoso/contoso-org:ref:refs/heads/*'"
      languageVersion = 1
    }
  }
  flexible_fic_json = replace(jsonencode(local.flexible_fic), "\"", "\\\"")
}

resource "terraform_data" "flexible_fic_hack" {
  input = {
    object_id       = azuread_application.entra-app.object_id
    credential_name = azuread_application.entra-app.display_name
  }

  provisioner "local-exec" {
    command = <<EOT
    az rest --method post --headers "Content-Type=application/json" --url https://graph.microsoft.com/beta/applications/${self.input.object_id}/federatedIdentityCredentials --body "${local.flexible_fic_json}"
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = "az rest --method delete --url https://graph.microsoft.com/beta/applications/${self.input.object_id}/federatedIdentityCredentials/${self.input.credential_name}"
  }

}

# resource "azapi_resource" "aks_federated_identity_credential" {
#   schema_validation_enabled = false
#   type      = "Microsoft.Graph/servicePrincipal@1.0"
#   name      = "FlexFic1"
#   parent_id = "/providers/Microsoft.Entra/servicePrincipals/dabbe08d-bd02-4c7f-a350-1f8f6c5d52b5"

#   body = {
#     properties = {
#       name = "FlexFic1"
#       audiences = ["api://AzureADTokenExchange"]
#       issuer    = "https://token.actions.githubusercontent.com"
#       claimsMatchingExpressions = {
#         value = "claims['sub'] matches 'repo:contoso/contoso-org:ref:refs/heads/*'"
#         languageVersion = 1
#       }
#     }
#   }
# }

# resource "azapi_resource" "aks_federated_identity_credential" {
#   count     = length(data.azuread_service_principal.cicd_service_principal) > 0 ? 1 : 0
#   type      = "Microsoft.Graph/servicePrincipals@1.0"
#   parent_id = "/providers/Microsoft.Entra/servicePrincipals/${one(data.azuread_service_principal.cicd_service_principal).id}"
#   name      = "aks_fic_${var.target.cluster.name}"

#   body = {
#     properties = {
#       name = "FlexFic1"
#       audiences = ["api://AzureADTokenExchange"]
#       issuer    = "https://token.actions.githubusercontent.com"
#       claimsMatchingExpressions = {
#         value = "claims['sub'] matches 'repo:contoso/contoso-org:ref:refs/heads/*'"
#         languageVersion = 1
#       }
#     }
#   }
# }

 