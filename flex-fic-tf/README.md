# Creating Flexible Federated Identity Credential

## CLI

```bash
SP_NAME=flexible-fic
# Create a service principal
az ad sp create-for-rbac -n $SP_NAME

SP_APP_ID=$(az ad sp list --display-name $SP_NAME --query "[0].appId" -o tsv)
APP_OBJ_ID=$(az ad app show --id $SP_APP_ID --query id -o tsv)

az rest --method post \
--headers "Content-Type=application/json" \
--url "https://graph.microsoft.com/beta/applications/${APP_OBJ_ID}/federatedIdentityCredentials" \
--body "{'name': 'FlexFic1', 'issuer': 'https://token.actions.githubusercontent.com', 'audiences': ['api://AzureADTokenExchange'], 'claimsMatchingExpression': {'value': 'claims[\'sub\'] matches \'repo:contoso/contoso-org:ref:refs/heads/*\'', 'languageVersion': 1}}"
```

## Terraform

```bash
cd tf
terraform init
terraform plan
terraform apply
```