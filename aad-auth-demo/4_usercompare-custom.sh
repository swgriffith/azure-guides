#!/bin/bash

# Load Env Vars
source 0_envvars.sh

mkdir temp

echo 'Get clusterUser credential'
az aks get-credentials -g $RG -n $CLUSTERNAME --user clusterUser

echo 'Get adminUser credential'
az aks get-credentials -g $RG -n $CLUSTERNAME --admin

echo 'Get clusterUser Cert'
kubectl config view -o jsonpath='{.users[?(@.name == "griffith")].user.client-certificate-data}' \
--raw|base64 --decode|openssl x509 -text -noout>./temp/griffith.txt

echo 'Get adminUser Cert'
kubectl config view -o jsonpath="{.users[?(@.name == \"clusterAdmin_${RG}_${CLUSTERNAME}\")].user.client-certificate-data}" \
--raw|base64 --decode|openssl x509 -text -noout>./temp/admin.txt

echo 'diff user and admin certs'
diff ./temp/griffith.txt ./temp/admin.txt -y|less

