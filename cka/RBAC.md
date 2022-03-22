# Kubernetes RBAC

## User Account Creation

We'll use an X.509 certificate for the user. This involves the following key steps:

1. Generate a private key file
2. Generate a Certificate Signing Request (CSR)
3. Sign the CSR with the kubernetes ca.crt
4. Create the kube config 
   
*Note:* In my testing I ran into an error that I was missing the .rnd file. I included the 'openssl rand' command below to create this file, but you may not need to.

```bash
# Create a directory for our files
mkdir cert && cd cert

# Generate the private key file
openssl rand -writerand ~/.rnd
openssl genrsa -out steveg.key 2048

# Generate the Cert Signing Request (CSR)
sudo openssl req -new -key steveg.key -out steveg.csr -subj "/CN=steveg/O=cka-practice"

# Sign the CSR with the Kubernetes cluster cert
sudo openssl x509 -req -in steveg.csr -CA /etc/kubernetes/pki/ca.crt -CAkey /etc/kubernetes/pki/ca.key -CAcreateserial -out steveg.crt -days 364

# Create the user in Kubernetes
kubectl config set-credentials steveg --client-certificate=steveg.crt \
--client-key=steveg.key

kubectl config set-context steveg-context --cluster=kubernetes --user=steveg

# Verify context
kubectl config get-contexts
CURRENT   NAME                          CLUSTER      AUTHINFO           NAMESPACE
*         kubernetes-admin@kubernetes   kubernetes   kubernetes-admin
          steveg-context                kubernetes   steveg
```

## Service Account creation

For services running inside the cluster that need their own identity, you may need to create a service account. 

```bash

kubectl create serviceaccount my-app
kubectl get sa
NAME      SECRETS   AGE
default   1         3h51m
my-app    1         31s
```

## Create Roles and Bindings

```bash

# Create the Role
cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: default
  name: pod-reader
rules:
- apiGroups: [""] # "" indicates the core API group
  resources: ["pods"]
  verbs: ["get", "watch", "list"]
EOF

kubectl get roles
NAME         CREATED AT
pod-reader   2022-03-22T20:17:45Z

# Create the RoleBinding
cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: read-pods
  namespace: default
subjects:
- kind: User
  name: steveg
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role 
  name: pod-reader 
  apiGroup: rbac.authorization.k8s.io
EOF

# Verify rights
kubectl auth can-i --list --as steveg
Resources                                       Non-Resource URLs   Resource Names   Verbs
selfsubjectaccessreviews.authorization.k8s.io   []                  []               [create]
selfsubjectrulesreviews.authorization.k8s.io    []                  []               [create]
pods                                            []                  []               [get watch list]
                                                [/api/*]            []               [get]
                                                [/api]              []               [get]
                                                [/apis/*]           []               [get]
                                                [/apis]             []               [get]
                                                [/healthz]          []               [get]
                                                [/healthz]          []               [get]
                                                [/livez]            []               [get]
                                                [/livez]            []               [get]
                                                [/openapi/*]        []               [get]
                                                [/openapi]          []               [get]
                                                [/readyz]           []               [get]
                                                [/readyz]           []               [get]
                                                [/version/]         []               [get]
                                                [/version/]         []               [get]
                                                [/version]          []               [get]
                                                [/version]          []               [get]

# Switch to the new user context for this role
kubectl config use-context steveg-context
kubectl get pods -n kube-system
Error from server (Forbidden): pods is forbidden: User "steveg" cannot list resource "pods" in API group "" in the namespace "kube-system"

# Create a ClusterRole for pod read access
cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: list-pods
rules:
- apiGroups:
  - ""
  resources:
  - pods
  verbs:
  - list
EOF

# Create the ClusterRoleBinding
cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
# This cluster role binding allows anyone in the "manager" group to read secrets in any namespace.
kind: ClusterRoleBinding
metadata:
  name: list-pods
subjects:
- kind: User
  name: steveg
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: list-pods
  apiGroup: rbac.authorization.k8s.io
EOF

kubectl auth can-i --list --as steveg
Resources                                       Non-Resource URLs   Resource Names   Verbs
selfsubjectaccessreviews.authorization.k8s.io   []                  []               [create]
selfsubjectrulesreviews.authorization.k8s.io    []                  []               [create]
                                                [/api/*]            []               [get]
                                                [/api]              []               [get]
                                                [/apis/*]           []               [get]
                                                [/apis]             []               [get]
                                                [/healthz]          []               [get]
                                                [/healthz]          []               [get]
                                                [/livez]            []               [get]
                                                [/livez]            []               [get]
                                                [/openapi/*]        []               [get]
                                                [/openapi]          []               [get]
                                                [/readyz]           []               [get]
                                                [/readyz]           []               [get]
                                                [/version/]         []               [get]
                                                [/version/]         []               [get]
                                                [/version]          []               [get]
                                                [/version]          []               [get]
pods                                            []                  []               [list get watch]

# Test access
kubectl config use-context steveg-context

kubectl get pods -n kube-system
NAME                                 READY   STATUS    RESTARTS        AGE
coredns-78fcd69978-pbhnk             1/1     Running   0               3h47m
coredns-78fcd69978-ph7v7             1/1     Running   0               3h46m

kubectl get svc -n kube-system
Error from server (Forbidden): services is forbidden: User "steveg" cannot list resource "services" in API group "" in the namespace "kube-system"

```


