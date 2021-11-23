
# Nginx Ingress Basic Auth

Create the AKS cluster

```bash
RG=EphDemoNginxBasicAuth
LOC=eastus
CLUSTER_NAME=nginxbasicauth

az group create -n $RG -l $LOC
az aks create -g $RG -n $CLUSTER_NAME
```

Install the Nginx Ingress Controller

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm install nginx-ingress ingress-nginx/ingress-nginx
```
Create an 'auth' file for user 'steve', and set password when prompted

```bash
htpasswd -c auth steve
kubectl create secret generic basic-auth --from-file=auth
```

Create the application deployment, ClusterIP service and ingress route

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: demoapp
  labels:
    app: demoapp
spec:
  containers:
  - image: "nginx"
    name: nginx
    ports:
    - containerPort: 80
      protocol: TCP
---
apiVersion: v1
kind: Service
metadata:
  name: demoapp
spec:
  selector:
    app: demoapp
  ports:
  - protocol: TCP
    port: 80
    targetPort: 80
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: demoapp
  annotations:
    kubernetes.io/ingress.class: nginx
    # type of authentication
    nginx.ingress.kubernetes.io/auth-type: basic
    # name of the secret that contains the user/password definitions
    nginx.ingress.kubernetes.io/auth-secret: basic-auth
    # message to display with an appropriate context why the authentication is required
    nginx.ingress.kubernetes.io/auth-realm: 'Authentication Required - foo'     
spec:
  rules:
  - http:
      paths:
      - path: /
        backend:
          service:
            name: demoapp
            port:
              number: 80
        pathType: Exact
EOF
```

Wait for the ingress object to return the public IP address.

```bash
watch kubectl get ingress,svc,pods
```

curl with and without password

```bash
curl -v http://20.81.53.163

*   Trying 20.81.53.163...
* TCP_NODELAY set
* Connected to 20.81.53.163 (20.81.53.163) port 80 (#0)
> GET / HTTP/1.1
> Host: 20.81.53.163
> User-Agent: curl/7.64.1
> Accept: */*
>
< HTTP/1.1 401 Unauthorized
< Date: Tue, 02 Nov 2021 16:50:46 GMT
< Content-Type: text/html
< Content-Length: 172
< Connection: keep-alive
< WWW-Authenticate: Basic realm="Authentication Required - foo"
<
<html>
<head><title>401 Authorization Required</title></head>
<body>
<center><h1>401 Authorization Required</h1></center>
<hr><center>nginx</center>
</body>
</html>
* Connection #0 to host 20.81.53.163 left intact
* Closing connection 0
```

```bash
curl -v http://20.81.53.163 -u 'foo:letmein'

*   Trying 20.81.53.163...
* TCP_NODELAY set
* Connected to 20.81.53.163 (20.81.53.163) port 80 (#0)
* Server auth using Basic with user 'foo'
> GET / HTTP/1.1
> Host: 20.81.53.163
> Authorization: Basic Zm9vOmxldG1laW4=
> User-Agent: curl/7.64.1
> Accept: */*
>
< HTTP/1.1 200 OK
< Date: Tue, 02 Nov 2021 16:51:10 GMT
< Content-Type: text/html
< Content-Length: 615
< Connection: keep-alive
< Last-Modified: Tue, 07 Sep 2021 15:21:03 GMT
< ETag: "6137835f-267"
< Accept-Ranges: bytes
<
<!DOCTYPE html>
<html>
<head>
<title>Welcome to nginx!</title>
<style>
html { color-scheme: light dark; }
body { width: 35em; margin: 0 auto;
font-family: Tahoma, Verdana, Arial, sans-serif; }
</style>
</head>
<body>
<h1>Welcome to nginx!</h1>
<p>If you see this page, the nginx web server is successfully installed and
working. Further configuration is required.</p>

<p>For online documentation and support please refer to
<a href="http://nginx.org/">nginx.org</a>.<br/>
Commercial support is available at
<a href="http://nginx.com/">nginx.com</a>.</p>

<p><em>Thank you for using nginx.</em></p>
</body>
</html>
* Connection #0 to host 20.81.53.163 left intact
* Closing connection 0
```