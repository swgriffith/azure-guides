#!/bin/bash

####################################################################
# Based on this gist from Henning Sprang
# https://gist.github.com/henning/2dda0b704426c66e78e355703a8dc177
####################################################################

# Load Env Vars
source 0_envvars.sh

NAMESPACE=default
USERNAME=griffith
GROUPNAME=cloudnativegbb

mkdir certs

openssl genrsa -out ./certs/${USERNAME}.key 2048

CSR_FILE=$USERNAME.csr
KEY_FILE=$USERNAME.key

openssl req -new -key ./certs/$KEY_FILE -out ./certs/$CSR_FILE -subj "/CN=$USERNAME/O=$GROUPNAME"

CERTIFICATE_NAME=$USERNAME.$NAMESPACE

cat <<EOF | kubectl create -f -
apiVersion: certificates.k8s.io/v1beta1
kind: CertificateSigningRequest
metadata:
  name: $CERTIFICATE_NAME 
spec:
  groups:
  - system:authenticated
  request: $(cat ./certs/$CSR_FILE | base64 | tr -d '\n')
  usages:
  - digital signature
  - key encipherment
  - client auth
EOF

kubectl certificate approve $CERTIFICATE_NAME

CRT_FILE=$USERNAME.crt

kubectl get csr $CERTIFICATE_NAME -o jsonpath='{.status.certificate}'  | base64 -D > ./certs/$CRT_FILE

cat <<EOF | kubectl create -f -
kind: Role
apiVersion: rbac.authorization.k8s.io/v1beta1
metadata:
  namespace: $NAMESPACE
  name: deployment-manager
rules:
- apiGroups: ["", "extensions", "apps"]
  resources: ["deployments", "replicasets", "pods"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"] # You can also use ["*"]
EOF


cat <<EOF | kubectl create -f -
kind: RoleBinding
apiVersion: rbac.authorization.k8s.io/v1beta1
metadata:
  name: $USERNAME-deployment-manager-binding
  namespace: $NAMESPACE
subjects:
- kind: User
  name: $USERNAME
  apiGroup: ""
roleRef:
  kind: Role
  name: deployment-manager
  apiGroup: ""
EOF

kubectl config set-credentials $USERNAME \
  --client-certificate=$(pwd)/certs/$CRT_FILE \
  --client-key=$(pwd)/certs/$KEY_FILE \
  --embed-certs

kubectl config set-context $USERNAME-context --cluster=$CLUSTERNAME --namespace=$NAMESPACE --user=$USERNAME

kubectl config use-context $USERNAME-context
