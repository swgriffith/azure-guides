#! /bin/bash

# Set Variables
export ARM_DEPLOYMENT_NAME="reddogbicep"
export SUBSCRIPTION_ID="62afe9fc-190b-4f18-95ac-e5426017d4c8"
export TENANT_ID="72f988bf-86f1-41af-91ab-2d7cd011db47"
export K3S_TOKEN='CAa6BYPyp+6NwLY5f3or'
export ADMIN_USER_NAME='reddogadmin'
export SSH_KEY_PATH="./ssh_keys"

az deployment group create \
  --name $ARM_DEPLOYMENT_NAME \
  --mode Incremental \
  --resource-group $RG_NAME \
  --template-file ../run.bicep \
  --parameters armDeploymentName=$ARM_DEPLOYMENT_NAME \
  --parameters subscriptionId=$SUBSCRIPTION_ID \
  --parameters tenantId=$TENANT_ID \
  --parameters k3sToken="$K3S_TOKEN" \
  --parameters adminUsername="$ADMIN_USER_NAME" \
  --parameters sshKeyPath="$SSH_KEY_PATH" 