#!/bin/bash
RG=EphAADDemos3
CLUSTERNAME=democluster

mkdir temp

echo 'Get clusterUser credential'
az aks get-credentials -g $RG -n $CLUSTERNAME --user clusterUser

echo 'Get clusterAdmin credential'
az aks get-credentials -g $RG -n $CLUSTERNAME --admin

echo 'Get clusterUser Cert'
kubectl config view -o jsonpath="{.users[?(@.name == \"clusterUser_${RG}_${CLUSTERNAME}\")].user.client-certificate-data}" \
--raw|base64 --decode|openssl x509 -text -noout>./temp/user.txt

echo 'Get adminUser Cert'
kubectl config view -o jsonpath="{.users[?(@.name == \"clusterAdmin_${RG}_${CLUSTERNAME}\")].user.client-certificate-data}" \
--raw|base64 --decode|openssl x509 -text -noout>./temp/admin.txt

echo 'diff user and admin certs'
diff ./temp/user.txt ./temp/admin.txt

