# Cross Node TCP Level Encryption

In this walkthrough I'll show a quick demo of [LinkerD](https://linkerd.io/) TLS encryption of TCP traffic.

## Setup

For this example I'm running an AKS cluster with kubenet as the network plugin. 

Lets install a set of test pods. To demonstrate basic tcp traffic, we'll create sender and receiver deployments of an ubuntu pod with netcat installed. We'll also make sure that the pods are on different nodes.

```bash
# Get a list of nodes in your cluster
kubectl get nodes

#############################################
# EDIT THE ubuntu-sender.yaml
# AND THE ubuntu-receiver.yaml
# NODESELECTOR TO PUT THEM ON DIFFERENT NODES
#############################################

# Deploy the sender and receiver
kubectl apply -f ubuntu-sender.yaml
kubectl apply -f ubuntu-receiver.yaml

NAME                               READY   STATUS    RESTARTS   AGE     IP            NODE                                NOMINATED NODE   READINESS GATES
ubuntu-receiver-5d56657ddc-vbd5g   1/1     Running   0          2m8s    10.100.2.14   aks-nodepool1-23454376-vmss000001   <none>           <none>
ubuntu-sender-d84768bb8-hsxd4      1/1     Running   0          2m14s   10.100.0.17   aks-nodepool1-23454376-vmss000000   <none>           <none>
```

Now open up three separate terminal windows. In the first two we'll kubectl exec into one of the above pods. In the third we'll ssh into the node our 'receiver' pod is running on. (See aks ssh setup guide [here](https://docs.microsoft.com/en-us/azure/aks/ssh)...I also like to use [ssh-jump](https://github.com/yokawasa/kubectl-plugin-ssh-jump))

```bash
# In terminal #1....update with your own pod name
kubectl exec -it ubuntu-receiver-5d56657ddc-vbd5g -- netcat -l 2929

# In terminal #2...again, update with your pod name and the ip should be the ip of the 'receiver' pod
# kubectl exec -it <senderPodName> -- netcat <receiverPodIP> 2929
kubectl exec -it ubuntu-sender-d84768bb8-hsxd4 -- netcat 10.100.2.14 2929

# In terminal #3 we're going to set up tshark to watch the traffic on the node
# ssh to the node where your receiver pod is running
kubectl ssh-jump aks-nodepool1-23454376-vmss000001

# Install tshark
sudo apt update;sudo apt install tshark -y

# Start watching the traffic on port 2929
udo tshark -i eth0 -f 'port 2929' -T fields -e ip.src -e tcp.srcport -e ip.dst -e tcp.dstport -e ip.proto -e data
```

So now we have an open netcat session between the sender and receiver pods, and we can see the traffic flowing at the node level through tshark. If I go to my 'sender' terminal and type 'test' and hit enter, we'll see 'test' appear on the receiver screen. More interesting, we'll see the following in our tshark window. As you can see, we had a message from 10.100.2.14 (our sender pod) to 10.100.0.17 (our receiver pod) with the data '746573740a'. Go to your favorite hex to ascii converter and you'll see thats the ascii for 'test'.

```bash
sudo tshark -i eth0 -f 'port 2929' -T fields -e ip.src -e tcp.srcport -e ip.dst -e tcp.dstport -e ip.proto -e data
Running as user "root" and group "root". This could be dangerous.
Capturing on 'eth0'
10.100.2.14	2929	10.100.0.17	50780	6	746573740a
10.100.0.17	50780	10.100.2.14	2929	6
```

So we see that our data comes through in un-encrypted hex form. Now lets get it encrypted. For this we'll install linkerd. 

Run through steps 1-3 or 4 in the [linkerd install guide](https://linkerd.io/2/getting-started/). I already have the cli installed, so here's what I ran.

```bash
# Check for compatibility issues
linkerd check --pre

# Install LinkerD
linkerd install | kubectl apply -f -

# Inject linkerd into the sender
linkerd inject ubuntu-sender.yaml | kubectl apply -f -

service "ubuntu-sender" skipped
deployment "ubuntu-sender" injected

service/ubuntu-sender unchanged
deployment.apps/ubuntu-sender configured

# Inject linkerd into the receiver
linkerd inject ubuntu-receiver.yaml | kubectl apply -f -

service "ubuntu-receiver" skipped
deployment "ubuntu-receiver" injected

service/ubuntu-receiver unchanged
deployment.apps/ubuntu-receiver configured

# Check out your pods
kubectl get pods -o wide
NAME                               READY   STATUS    RESTARTS   AGE     IP            NODE                                NOMINATED NODE   READINESS GATES
ubuntu-receiver-54d7cdfcc8-p7dpl   2/2     Running   0          10m     10.100.2.18   aks-nodepool1-23454376-vmss000001   <none>           <none>
ubuntu-sender-579f56bd89-4dm47     2/2     Running   0          10m     10.100.0.20   aks-nodepool1-23454376-vmss000000   <none>           <none>
```

Notice, in the above, that we now have 2/2 for each pod? This is because of what linkerd injects to intercept our traffic and encrypt

Now lets go back to our 3 terminals and reconnect. The two pods would have been killed when you applied the update.

```bash
# In terminal #1....update with your own pod name
kubectl exec -it ubuntu-receiver-54d7cdfcc8-p7dpl -- bash
# Install and run netcat 
apt update; apt install netcat -y
# Run netcat
netcat -l 2929

# In terminal #2...again, update with your pod name and the ip should be the ip of the 'receiver' pod
kubectl exec -it ubuntu-sender-579f56bd89-4dm47 -- bash
apt update; apt install netcat -y
# Run netcat
netcat 10.100.2.18 2929

# In terminal 3....we'll run a slightly different tshark command so that we can see more data
sudo tshark -i eth0 -f 'port 2929'
```

Now start sending messages from the sender to the receiver and watch the tshark output. You should see something like the following for each message you send:

```bash
sudo tshark -i eth0 -f 'port 2929'
Running as user "root" and group "root". This could be dangerous.
Capturing on 'eth0'
    1 0.000000000  10.100.0.20 → 10.100.2.18  TLSv1.2 92 Application Data
    2 0.000090400  10.100.2.18 → 10.100.0.20  TCP 66 2929 → 52814 [ACK] Seq=1 Ack=27 Win=501 Len=0 TSval=106423588 TSecr=2831841303
```

Note, in the above, the TLSv1.2 in the initial request from the sender to the receiver, indicating the traffic is encrypted.
