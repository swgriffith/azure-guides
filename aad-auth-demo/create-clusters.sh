#!/bin/bash

RG=EphAADDemos
LOC=eastus
CLUSTERNAME=democluster

# Create Resource Group
az group create -n $RG -l $LOC

# Create non-AAD Cluster
az aks create -g $RG -n $CLUSTERNAME -c 1
az aks get-credentials -g $RG -n $CLUSTERNAME
az aks get-credentials -g $RG -n $CLUSTERNAME --admin

# Create non-AAD Cluster
az aks create -g $RG -n $CLUSTERNAME-aad -c 1 --enable-aad
az aks get-credentials -g $RG -n $CLUSTERNAME-aad
az aks get-credentials -g $RG -n $CLUSTERNAME-aad --admin

kubectl config use-context $CLUSTERNAME