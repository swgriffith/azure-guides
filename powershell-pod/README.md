# Windows Server Debug Pod Example

## Dockerfile

```
FROM mcr.microsoft.com/windows/servercore:ltsc2019

WORKDIR "C:\\"

# Install Chocolatey
RUN powershell -Command Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))

# Install Apache Bench
RUN choco install -y apache-httpd
RUN setx path "%path%;C:\Users\ContainerAdministrator\AppData\Roaming\Apache24\bin"
```

## Pod

```yaml
apiVersion: v1
kind: Pod
metadata:
  labels:
    run: windebug
  name: windebug
spec:
  containers:
  - image: stevegriffith/windebug
    name: windebug
    command: ["powershell.exe", "-command"]
    args: ["while($true){Start-Sleep -Seconds 30}"]
  dnsPolicy: ClusterFirst
  restartPolicy: Always
  nodeSelector:
    kubernetes.io/hostname: aksnpwin000001
```

## Test Commands

```bash
# Deploy the pod
kubectl apply -f powershell-pod.yaml

# Run an apache bench test
kubectl exec -it windebug -- powershell -Command ab -c 10 -n 100 http://bing.com/

# Node Debug
kubectl get nodes
NAME                                STATUS   ROLES   AGE   VERSION
aks-nodepool1-34160815-vmss000000   Ready    agent   11d   v1.23.5
aks-nodepool1-34160815-vmss000001   Ready    agent   10d   v1.23.5
aksnpwin000000                      Ready    agent   11d   v1.23.5
aksnpwin000001                      Ready    agent   10d   v1.23.5

kubectl debug node/aksnpwin000000 -it --image=stevegriffith/windebug
```