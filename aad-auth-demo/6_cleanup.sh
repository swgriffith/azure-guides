#!/bin/bash

RG=EphAADDemos

az group delete -n $RG -y --no-wait
az ad sp delete --id $(cat ./temp/sp.json| jq -r .appId)
rm ~/.kube/config

rm -rf ./temp
rm -rf ./certs

