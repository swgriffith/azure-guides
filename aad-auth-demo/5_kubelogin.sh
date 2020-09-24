#!/bin/bash
RG=EphAADDemos
CLUSTERNAME=democluster-aad

echo "Create Service Principal..."
az ad sp create-for-rbac --skip-assignment -o json > ./temp/sp.json

export AAD_SERVICE_PRINCIPAL_CLIENT_ID=$(cat ./temp/sp.json| jq -r .appId)
export AAD_SERVICE_PRINCIPAL_CLIENT_SECRET=$(cat ./temp/sp.json| jq -r .password)

OBJID=$(az ad sp show --id $AAD_SERVICE_PRINCIPAL_CLIENT_ID --query objectId -o tsv)

rm $HOME/.kube/config
az aks get-credentials -g $RG -n $CLUSTERNAME --admin

echo "Create cluster-admin role binding for sp....."
cat << EOF | kubectl apply -f -
kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: sp-admin
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: User
  name: "${OBJID}"
EOF

rm $HOME/.kube/config

az aks get-credentials -g $RG -n $CLUSTERNAME

export KUBECONFIG=$HOME/.kube/config

echo "Convert kubeconfig..."
kubelogin convert-kubeconfig -l spn

kubectl get nodes