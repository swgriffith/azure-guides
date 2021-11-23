# Azure Container Registry Build Tasks

## Setup

Create an ACR
```bash
RG=EphACRTaskDemo
LOC=eastus
ACR_NAME=grifftaskacr

az group create -n $RG -l $LOC
az acr create -g $RG -n $ACR_NAME --sku Premium
```

## Quick Task

```bash
az acr build --registry $ACR_NAME --image testfun:v1 .
```

## Trigger on source code update

```bash
ACCESS_TOKEN=''
az acr task create -t testtrigger:{{.Run.ID}} \
-n testtrigger \
-r $ACR_NAME  \
-f Dockerfile \
--no-push true \
--auth-mode None \
-c https://github.com/Azure-Samples/acr-build-helloworld-node.git \
--commit-trigger-enabled true \
--pull-request-trigger-enabled true \
--git-access-token $ACCESS_TOKEN
```
