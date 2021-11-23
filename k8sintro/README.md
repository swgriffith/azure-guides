# Kubernetes Intro

## Links

- [Kubernetes Docs](https://kubernetes.io/docs/home/)
- [Kubernetes Cheat Sheet](https://kubernetes.io/docs/reference/kubectl/cheatsheet/)
- Certifications
  - [CKAD](https://training.linuxfoundation.org/certification/certified-kubernetes-application-developer-ckad/)
  - [CKA](https://training.linuxfoundation.org/certification/certified-kubernetes-administrator-cka/)
  - [CKS](https://training.linuxfoundation.org/certification/certified-kubernetes-security-specialist/)

## Aliases are your friend

When working with the command line you'll be typing a LOT of things repeatedly. You can easily create alias for common commands to speed up your typing. The most common is to alias k=kubectl to save yourself from typing kubectl over and over again.

In your .bashrc or .zshrc files add the following

```bash
alias k=kubectl
```

## Common Commands

Here are some of the commands you will use most commonly when working with your cluster

```bash
# Context Management
kubectl config get-contexts # List all current contexts in ~/.kube/config
kubectl config set-context --current --namespace default # Set default namespace

# Apply Changes
kubectl apply -f <file path/url>
kubectl delete -f <file path/url>

# Gets
kubectl get ns # Get Namespaces
kubectl get pods # Get Pods
kubectl get rs # Get Replica Sets
kubectl get deploy # Get Deployments
kubectl get svc # Get Services
kubectl get ds # Get Daemonsets
kubectl get secrets # Get Secrets
kubectl get configmaps # Get Config Maps

# Deletes
kubectl delete ns # Delete Namespaces
kubectl delete pods # Delete Pods
kubectl delete rs # Delete Replica Sets
kubectl delete deploy # Delete Deployments
kubectl delete svc # Delete Services
kubectl delete ds # Delete Daemonsets
kubectl delete secrets # Delete Secrets
kubectl delete configmaps # Delete Config Maps

# Describe a resource
kubectl describe <pod,svc,etc>

# Deletes with force
kubectl delete <pod,ds,rs,etc> --grace-period=0 --force

# Check pod/container logs
kubectl logs <pod> # -f will 'follow'
# If the pod has more than one container
kubectl logs <pod> -c <container name>
```

In scripts it's often helpful to execute fully from within the script rather than referencing external files. The Linux "cat <<EOF" syntax is very helpful for this.

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
  restartPolicy: Never
EOF
```

### Kubectl Extensions

You can easily extend kubectl to enable your own shortcuts and additional features. Details are [here](). Many people have created extensions you can leverage. Here are a few of my favorites.

- [kubectx](https://github.com/ahmetb/kubectx)
- [ssh-jump](https://github.com/yokawasa/kubectl-plugin-ssh-jump)

Not technically a plugin, but still very useful for cluster navigation:

- [k9s](https://k9scli.io/)

And don't forget the kubernetes and docker extensions for vscode.

- [Kubernetes](https://marketplace.visualstudio.com/items?itemName=ms-kubernetes-tools.vscode-kubernetes-tools)
- [Docker](https://marketplace.visualstudio.com/items?itemName=ms-azuretools.vscode-docker)
