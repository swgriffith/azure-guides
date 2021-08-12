# EMQX in AKS with TLS via Traefik TCP Ingress Routes

In the following I'll run through the steps to get EMQX running in an AKS cluster using Traefik TCP Ingress Routes and getting certificates from LetsEncrypt.

First lets create the AKS cluster. We're going to keep it very generic.

```bash
RG=EMQXAKSDemo
LOC=eastus
CLUSTER_NAME=emxqdemo

az group create -n $RG -l $LOC
az aks create -g $RG -n $CLUSTER_NAME
az aks get-credentials -g $RG -n $CLUSTER_NAME
```

Next we'll install [cert-manager](https://cert-manager.io/docs/) which will be used to automatically retrieve certs from [LetsEncrypt](https://letsencrypt.org/) and store them as Kubernetes Secrets.

```bash
kubectl apply -f https://github.com/jetstack/cert-manager/releases/latest/download/cert-manager.yaml
```

Now lets install [Traefik](https://traefik.io/) as our ingress controller. We'll be using the helm chart approach. 

In order to expose port 8883 for mqtt, we need to create an entrypoint in Traefik. This is configured when you deploy the controller via the helm values file. You can pull the latest values file from [here](https://github.com/traefik/traefik-helm-chart/blob/master/traefik/values.yaml) and edit it as follows, or use the values file I've provided. Just keep in mind that depending on when you're reading this, my file may be out of date.

Edit the values file to include the following under the 'ports' section:
```yaml
  mqtt:
    port: 8883
    expose: true
    exposedPort: 8883
    # The port protocol (TCP/UDP)
    protocol: TCP
```

Install Traefik. We'll install Traefik and EMQX in the default namespace for simplicity, but you can adjust.

```bash
helm repo add traefik https://helm.traefik.io/traefik
helm repo update
helm install --namespace=default traefik traefik/traefik -f values.yaml
```

Install EMQX

```bash
helm repo add emqx https://repos.emqx.io/charts 
helm repo update
helm install my-emqx emqx/emqx -n default
```

Wait until all of your Traefik and EMQX pods are running.

```bash
watch kubectl get svc,pods

NAME                       TYPE           CLUSTER-IP    EXTERNAL-IP   PORT(S)                                                           AGE
service/kubernetes         ClusterIP      10.0.0.1      <none>        443/TCP                                                           12m
service/my-emqx            ClusterIP      10.0.85.137   <none>        1883/TCP,8883/TCP,8081/TCP,8083/TCP,8084/TCP,18083/TCP            2m52s
service/my-emqx-headless   ClusterIP      None          <none>        1883/TCP,8883/TCP,8081/TCP,8083/TCP,8084/TCP,18083/TCP,4370/TCP   2m52s
service/traefik            LoadBalancer   10.0.131.35   20.81.85.43   8883:31766/TCP,80:30267/TCP,443:32474/TCP                         3m40s

NAME                           READY   STATUS    RESTARTS   AGE
pod/my-emqx-0                  1/1     Running   0          2m52s
pod/my-emqx-1                  1/1     Running   0          2m40s
pod/my-emqx-2                  1/1     Running   0          2m25s
pod/traefik-666648656c-rccqx   1/1     Running   0          3m40s
```

While you're waiting, when your 'EXTERNAL-IP' is populated with the Azure Load Balancer public IP associated with your Traefik ingress, you can go and create your A record in your DNS. Note, you can use Traefik with a self signed certificate and a local DNS record in your /etc/hosts, but thats not covered here.

For this I created a A record pointing emqxtlsdemo.stevegriffith.io to my ingress public IP at 20.81.85.43.

Next you need to create the cert issuer and cert. Edit the file in this repo called ca-issuer-cert-emqx.yaml. You'll want to update the email address in the Issuer, and change all of the names and host names to match your target DNS record.

```yaml
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
  namespace: default
spec:
  acme:
    # The ACME server URL
    server: https://acme-v02.api.letsencrypt.org/directory
    # Email address used for ACME registration
    email: steve.griffith@microsoft.com
    # Name of a secret used to store the ACME account private key
    privateKeySecretRef:
      name: letsencrypt-prod
    # Enable the HTTP-01 challenge provider
    solvers:
    - http01:
        ingress:
          class: traefik

---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: emqxtlsdemo.stevegriffith.io
  namespace: default
spec:
  dnsNames:
    - emqxtlsdemo.stevegriffith.io
  secretName: emqxtlsdemo.stevegriffith.io
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
```

Apply the cluster issuer and certificate.

```bash
kubectl apply -f ca-issuer-cert-emqx.yaml
```

Watch the status of your certificate and issuer. You should see the ready state of the certificate go to 'True' when it has been issued by LetsEncrypt and stored

```bash
watch kubectl get clusterissuer,certificate 

NAME                                             READY   AGE
clusterissuer.cert-manager.io/letsencrypt-prod   True    105s

NAME                                                       READY   SECRET                         AGE
certificate.cert-manager.io/emqxtlsdemo.stevegriffith.io   True    emqxtlsdemo.stevegriffith.io   105s
```

Before we move on, lets get the Traefik dashboard running so we can see our entrypoint is available and watch our ingress come online. We already had the dashboard enabled by default in the values.yaml file, so we just need to create an ingress route to access it (Note: You can also just port-forward if you prefer.)

```bash
# Port Forward
kubectl port-forward $(kubectl get pods --selector "app.kubernetes.io/name=traefik" --output=name) 9000:9000
```

For my dashboard I created an A record for traefikdemo.stevegriffith.io pointing to the same ingress service EXTERNAL-IP (20.81.85.43). 

After creating your A record you can update the ingressroute-traefik-dashboard.yaml file in this repo with the updated host name.

You should now be able to navigate to your dashboard at your specified FQDN on port (ex. http://traefikdemo.stevegriffith.io/dashboard/).

In the dashboard, under 'Entry Points' you should see your MQTT on port 8883 entry point.

Now, lets create the TCP Ingress Route. Edit the ingressroutetcp-emqx.yaml file in this repo, and update the host and secret names to match your FQDN. 

Apply the ingress route.

```bash
kubectl apply -f ingressroutetcp-emqx.yaml 
```

You should now have a working TCP endpoint using your cert from LetsEncrypt! Let's test it!

```bash
openssl s_client -connect emqxtlsdemo.stevegriffith.io:8883 -servername emqxtlsdemo.stevegriffith.io -showcerts 
```

Your output should look something like this:

```bash
openssl s_client -connect emqxtlsdemo.stevegriffith.io:8883 -servername emqxtlsdemo.stevegriffith.io -showcerts
CONNECTED(00000005)
depth=3 O = Digital Signature Trust Co., CN = DST Root CA X3
verify return:1
depth=2 C = US, O = Internet Security Research Group, CN = ISRG Root X1
verify return:1
depth=1 C = US, O = Let's Encrypt, CN = R3
verify return:1
depth=0 CN = emqxtlsdemo.stevegriffith.io
verify return:1
....
```