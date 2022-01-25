# CSR Signing Example

Using the kubelet-serving signer to create a CSR and certificate.

Create a file named req.conf with the following

```bash
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no
[req_distinguished_name]
C = US
ST = NY
L = New York
O = system:nodes
OU = system:nodes
CN = system:node:example.com
[v3_req]
keyUsage = keyEncipherment, digitalSignature
extendedKeyUsage = serverAuth
subjectAltName = @alt_names
[alt_names]
DNS.1 = www.example.com
DNS.2 = example.com
DNS.3 = www.example1.com
DNS.4 = example1.com
```

Create a file called csr.yaml with the following

```bash
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: myuser
spec:
  request: <csr base64 encoded to be added here>
  signerName: kubernetes.io/kubelet-serving
  expirationSeconds: 86400  # one day
  usages:
  - "digital signature"
  - "key encipherment"
  - "server auth"
```

Run the following to create the CSR and get the base64 encoded csr value

```bash
openssl req -new -out certificate.csr -newkey rsa:2048 -nodes -sha256 -keyout certificate.key -config req.conf
cat certificate.csr | base64 | tr -d "\n"
#insert the output of the above into csr.yaml

# Create the csr
kubectl apply -f csr.yaml

# Approve the csr
kubectl certificate approve myuser

# Check the status of the csr
kubectl get csr/myuser -o yaml
```
