# Creating and testing a windows nodepool privildged daemonset

## Cluster Creation

In this setup I'll be joining my cluster to my home network, so I'll be providing a VNet/Subnet ID, but you can leave that off if you have other plans for how to connect to the windows node


```bash
RG=EphWindowsCluster
LOC=eastus
CLUSTER_NAME=wincluster
WINDOWS_USERNAME=griffith
# Optional: Existing Vnet Subnet ID
VNET_SUBNET_ID=

# Create the resouce group
az group create -n $RG -l $LOC

# Create the cluster
# Note: You will be promted to enter and admin password for windows
az aks create -g $RG \
-n $CLUSTER_NAME \
--network-plugin azure \
--vnet-subnet-id $VNET_SUBNET_ID \
--node-count 1 \
--windows-admin-username $WINDOWS_USERNAME 

# Add the windows nodepool
az aks nodepool add \
--resource-group $RG \
--cluster-name $CLUSTER_NAME \
--os-type Windows \
--name npwin \
--node-count 1

# Get Credentials
az aks get-credentials -g $RG -n $CLUSTER_NAME --admin
```

## The Script Runner DaemonSet

Here's a breakdown of the script runner daemonset.

### The Script

To get the script into the pod you have many options. 

1. You could do an Invoke-WebRequest to download the file from an external site
2. You could bake the script into your container image as part of the Docker build
3. You could manage the script as a Kubernetes config map

I'm going with option 3. As you can see, I have a simple script that gets the status of the W32Time service, stops it, gets the status again to show it's stopped, sleeps for 20 seconds and then starts the service back up. This will execute the host level as you'll see in the next section, so you can include anything here that you could run if you were directly connected to the host machine.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: powershell-script
  namespace: default
data:
  stopservice.ps1: |
    Get-Service -Name W32TIme
    Stop-Service -Name W32Time
    Get-Service -Name W32TIme
    Start-Sleep -Seconds 20
    Start-Service -n W32Time
    Get-Service -Name W32TIme
    Start-Sleep -Seconds 20
```

### The Privileged DaemonSet

Now here's the fun part. We need this pod to run with privileged access on the host, so we need to set some security options.

```yaml
securityContext:
windowsOptions:
    hostProcess: true
    runAsUserName: "NT AUTHORITY\\system"
```

I also want this pod to run on the host network interface, instead of creating a virtual adapter for the pod. This isnt really needed for this script, but just wanted to show how it works.

```yaml
hostNetwork: true
```

We want this to run on only windows nodes, so I include the node selector.

```yaml
nodeSelector:
  kubernetes.io/os: windows
```

We want to mount the configmap that is holding our powershell script into a volume in the pod, so we include both the volume definition and the volume mount in the pod.

```yaml
# The mount in the pod
volumeMounts:
- name: script
  mountPath: "/script"

# And the volume
# Note that we set the file mode
volumes:
  - name: script
    configMap:
      name: powershell-script
      defaultMode: 0555  
```

Finally, we need to execute the script when the pod starts. This pod will restart each time the script completes, but you could change that by adding a sleep infinity at the end of the script. I'll just let it run.

>*NOTE:* It's important to make sure all of your paths match up, and they should be relative. Don't try to use C: as the script mounts in to the pod and its relative filesystem.

```yaml
command: ["powershell.exe", "-command"]
args: ["./script/stopservice.ps1"]
```

When complete, the yaml file will look like the following:

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  labels:
    app: powershell-runner
  name: powershell-runner
  namespace: default
spec:
  selector:
    matchLabels:
      app: powershell-runner
  template:
    metadata:
      labels:
        app: powershell-runner
    spec:
      securityContext:
        windowsOptions:
          hostProcess: true
          runAsUserName: "NT AUTHORITY\\system"
      hostNetwork: true
      containers:
        - name: powershell-runner
          image: mcr.microsoft.com/windows/nanoserver:1809
          imagePullPolicy: Always
          command: ["powershell.exe", "-command"]
          args: ["./script/stopservice.ps1"]
          volumeMounts:
          - name: script
            mountPath: "/script"          
      nodeSelector:
        kubernetes.io/os: windows
      volumes:
        - name: script
          configMap:
            name: powershell-script
            defaultMode: 0555        
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: powershell-script
  namespace: default
data:
  stopservice.ps1: |
    Get-Service -Name W32TIme
    Stop-Service -Name W32Time
    Get-Service -Name W32TIme
    Start-Sleep -Seconds 20
    Start-Service -n W32Time
    Get-Service -Name W32TIme
    Start-Sleep -Seconds 20
```

### Running the DaemonSet

From the command line run the following:

```bash
kubectl apply -f powershell-runner-ds.yaml

# Sample Output
daemonset.apps/powershell-runner created
configmap/powershell-script created

# Check Status
kubectl get configmaps,pods
NAME                          DATA   AGE
configmap/kube-root-ca.crt    1      86m
configmap/powershell-script   1      20s

NAME                          READY   STATUS    RESTARTS   AGE
pod/powershell-runner-wsc98   1/1     Running   0          20s

# Check the pod logs
kubectl logs -f powershell-runner-wsc98

Status   Name               DisplayName
------   ----               -----------
Running  W32TIme            Windows Time
Stopped  W32TIme            Windows Time
Running  W32TIme            Windows Time
```

>*NOTE:* As mentioned above, this pod will restart each time the script completes. You could end the script with an infinite sleep if you dont want to see restarts.

### Validating Run

Open an SSH or RDP session to your Windows host and run the following:

```powershell
while(1){Get-Service -Name W32TIme;sleep 5}
```

You should see output like the followingL

```powershell
Status   Name               DisplayName
------   ----               -----------
Running  W32TIme            Windows Time
Running  W32TIme            Windows Time
Running  W32TIme            Windows Time
Running  W32TIme            Windows Time
Running  W32TIme            Windows Time
Running  W32TIme            Windows Time
Stopped  W32TIme            Windows Time
Stopped  W32TIme            Windows Time
Stopped  W32TIme            Windows Time
Stopped  W32TIme            Windows Time
Running  W32TIme            Windows Time
Running  W32TIme            Windows Time
Running  W32TIme            Windows Time
Running  W32TIme            Windows Time
Running  W32TIme            Windows Time
Stopped  W32TIme            Windows Time
Stopped  W32TIme            Windows Time
Stopped  W32TIme            Windows Time
Stopped  W32TIme            Windows Time
Running  W32TIme            Windows Time
Running  W32TIme            Windows Time
Running  W32TIme            Windows Time
Running  W32TIme            Windows Time
```