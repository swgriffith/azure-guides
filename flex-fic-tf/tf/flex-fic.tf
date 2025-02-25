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