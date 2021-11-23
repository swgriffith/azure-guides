#!/bin/bash

# Need to first register for the preview
# az feature register --name NodePublicIPPreview --namespace Microsoft.ContainerService
# az feature show --namespace Microsoft.ContainerService --name NodePublicIPPreview

# Create the service principal for the cluster and set in azuredeploy.parameters.json
# az ad sp create-for-rbac --skip-assignment



# Set environment variables
RG=TrashManagedIdent
LOC=eastus

az group create -g $RG -l $LOC

az group deployment create -g $RG --template-file azuredeploy.json --parameters @azuredeploy.parameters.json --verbose
