# Using Kubelogin with AKS via Terraform

### Special Thanks!

Thanks to [Daniel Neumann](https://www.danielstechblog.io/about-me/) for the original article we used to get this started, which you can find [here](https://www.danielstechblog.io/azure-kubernetes-service-using-kubernetes-credential-plugin-kubelogin-with-terraform/).

Thanks to [Ray Kao](https://github.com/raykao) for working out a bunch of bugs we hit and dropping some sweet PRs.

## Overview

In this walkthrough we'll use the Terraform AKS provider to create an AKS cluster that has Azure AD enabled, Azure AD RBAC enabled and has disabled local accounts. That means that this cluster will require Azure Active Directory authentication and RBAC and will explicitly not allow local accounts.

We'll then use the Terraform Kubernetes provider to create a deployment in the cluster using a valid service principal.

### Real Talk

After testing this out, in my opinion...as well as some of my peers, creating the cluster and deploying workloads in the same Terraform script adds some unecessary complexity and brittleness. You'll likely have a better exerience having a Terraform script for the infrastructure provisioning and a separate approach (ex. Flux, Argo, Other CD Pipeline) to deploy your workloads to the cluster.

That said...lets give this a go.

## Requirements

Here are the items we'll assume you've already set up before running this deployment.

#### 1. An Azure AD Group for your cluster Administrators
When you enable Azure AD on AKS and disable local accounts, you are required to provide at least one group ID for the 'Administrators' of the cluster.

#### 2. A service principal that is a member of the Administrators group
We'll be running a deployment against the cluster, and to do that we'll need a valid user. For this example we're using a service principal. You could adjust this to use a managed identity as well if you prefer, but you'll need to modify the template. You will need both the 'client id' and a 'client secret' for this service principal, creation of which is outside the scope of this guide...for now.

#### 3. Kubelogin must be installed on the machine running the terraform deployment
Accessing Azure Active Directory enabled clusters with a non-interactive login flow (ex. via automated deployment pipeline) requires that you use the [kubelogin](https://azure.github.io/kubelogin/index.html) project. Kubelogin will handle the OAuth flows needed to get the cluster access token.

## Running the deployment

First you need to create a new 'terraform.tfvars' file at the same level as the main.tf file. That file should look like the following, but with your own values applied for the AAD tenant ID, Admins AAD Group ID, client id and client secret.

```bash
admin_group_object_ids = ["xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"]
tenant_id = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
client_id = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
client_secret = "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
```

Next we'll run the deployment commands.

```bash
# Initialize Terraform
terraform init

# Run Terraform Plan
terraform plan

# Deplouy
terraform apply --auto-approve
```

## How this works

While the deployment is running, lets cover how this works. As noted above our cluster is locked down to only Azure AD users and no local kubernetes accounts, like the default admin account. Additionally, since the cluster is AAD enabled for authentication, you typically would get a device code flow prompt when trying to run deployments via kubectl. Since the deployment will be done by the Terraform Kubernetes provider, we'll need to use kubelogin, which we can do via the provider's 'exec' option.

Here are the steps:

1. Resource Group and Cluster are created
2. The Kubernetes provider runs 'kubelogin get-token' passing in some of the details from the cluster creation (ex. API Server FQDN) as well as the service principal credentials. It also needs the application ID of the AKS cluster login server, which we get via the 'azuread_service_principal' block.
3. The 'kubernetes_deployment' block runs using the kubernetes provider, which now has it's access token, to run the nginx deployment

## Conclusion

Once the above deployment completes, you should be able to connect to your cluster (Azure Portal or kubectl) and see the nginx deployment is running.

To clean up your deployment, there is a bit of a state management issue with this deployment, since both the cluster and deployment were in one run. I'll probably split that out later. For now, we'll just delete the nginx deployment from state before deleting the cluster.

```bash
# Remove the nginx deployment from state
terraform state rm kubernetes_deployment.nginx

# Destroy the deployment
terraform destroy --auto-approve
```

