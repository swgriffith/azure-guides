#!/bin/bash

RG=EphAADDemos

az group delete -n $RG -y --no-wait

rm ~/.kube/config

rm -rf ./temp
rm -rf ./certs