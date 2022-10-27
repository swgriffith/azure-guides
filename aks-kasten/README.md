
# Introduction

The following content and scripts walk through the setup of an [Azure Kubernetes Service](https://azure.microsoft.com/en-us/products/kubernetes-service/#overview) cluster, installation of [Elastic Search](https://www.elastic.co/what-is/elasticsearch) and the deployment and test of [Kasten K10](https://www.kasten.io/) for data protection and recovery.

This work is HEAVILY based on the work of my peer [Mohammad Nofal](https://www.linkedin.com/in/mnofal/). Thanks for this awesome work!

[https://github.com/mohmdnofal/aks-best-practices/tree/master/aks-kasten](https://github.com/mohmdnofal/aks-best-practices/tree/master/aks-kasten)

First, we'll walk through the set up of the primary cluster, deployment of Elastic Search and Kasten K10. After that we'll do some local cluster recorvery tests, and then set up a secondary cluster that matches the primary. Once running, we'll export the Elastic Search data from the primary and restore to the secondary.

* Step 1: [Primary Cluster Setup and Local Recovery](./primary-cluster-setup.md)
* Step 2: [Secondary Cluster Setup and Cross Region Recovery](./secondary-cluster-setup.md)


