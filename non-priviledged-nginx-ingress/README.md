# Running Nginx Ingress in AKS without Priviledged Escalation

## Intro



## Setup

Lets create the sample cluster. 

> *NOTE:* For the purposes of this demo I'll use the Azure Policy add-on. You can use whatever mechanism you prefer to block priviledged pods.

```bash
RG=NonPriviledgeNginxIngress
LOC=eastus
CLUSTER_NAME=nginxtest

az group create -n $RG -l $LOC
az aks create -g $RG -n $CLUSTER_NAME

az aks enable-addons --addons azure-policy --name $CLUSTER_NAME --resource-group $RG

az aks get-credentials -g $RG -n $CLUSTER_NAME
```

Jump out to the Azure portal and apply a policy to block priviledged escalation. You can find the details [here](https://docs.microsoft.com/en-us/azure/aks/use-azure-policy).

Now lets test the policy works.

> *NOTE:* Azure Policy can take 20min or more to apply a policy. If you want a faster implementation you can look at running OPA and Gatekeeper directly.

```bash
cat << EOF|kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  labels:
    run: ubuntu
  name: ubuntu
spec:
  containers:
  - image: ubuntu
    name: ubuntu
    command: [ "/bin/bash", "-c", "--" ]
    args: [ "while true; do sleep 30; done;" ]
    securityContext:
      allowPrivilegeEscalation: true    
  restartPolicy: Never
EOF

# Output will look something like this:
Error from server ([azurepolicy-psp-container-no-privilege-esc-f2edbdf265fc03413ebc] Privilege escalation container is not allowed: ubuntu): error when creating "STDIN": admission webhook "validation.gatekeeper.sh" denied the request: [azurepolicy-psp-container-no-privilege-esc-f2edbdf265fc03413ebc] Privilege escalation container is not allowed: ubuntu
```

Now lets install [nginx-ingress](https://github.com/kubernetes/ingress-nginx) and watch it fail. :-D

Actually, it will just spin for a while waiting for the deployment to complete. If you cancel, you'll see the status as 'Pending Install'

```bash
kubectl create ns ingress-nginx

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm install nginx-ingress ingress-nginx/ingress-nginx \
--namespace ingress-nginx
```

## Solution

So what's causing this? The issue is the nginx controller binds to ports 80 and 443, which are considered [priviledged ports](https://www.w3.org/Daemon/User/Installation/PrivilegedPorts.html). 

We can address this issue a few ways.

1. We can set allowPrivilegeEscalation to false and then enable [CAP_NET_BIND_SERVICE](https://man7.org/linux/man-pages/man7/capabilities.7.html), which will allow the port binding to ports below 1024.
2. We can change the pod port bindings to something greater than 80 and 443 and then map the exposed service ports (80 and 443) back to the new pod ports


### Option 1

```bash
helm install nginx-ingress ingress-nginx/ingress-nginx \
--namespace ingress-nginx \
--set controller.image.allowPrivilegeEscalation=false \
--set controller.containerPort.http=8080 \
--set controller.containerPort.https=8081 \
--set controller.service.ports.http=80 \
--set controller.service.ports.https=443 \
--set controller.service.targetPorts.http=8080 \
--set controller.service.targetPorts.https=8081 \
--set controller.extraArgs.http-port=8080 \
--set controller.extraArgs.https-port=8081

helm install nginx-ingress ingress-nginx/ingress-nginx \
--namespace ingress-nginx -f values.yaml \

```