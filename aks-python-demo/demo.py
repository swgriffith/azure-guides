from azure.identity import AzureCliCredential
from azure.mgmt.containerservice import ContainerServiceClient
import os
import adal
from kubernetes import client, config
import urllib3

# Disable the TLS Warning, since we know and trust the ca
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# Get the CLI Credential for the current logged in user
credential = AzureCliCredential()

# Get the subscription ID env variable
subscription_id = os.environ.get("AZURE_SUBSCRIPTION_ID")

# Get the Service Principal Details
tenant_id = os.environ.get("TENANT_ID")
app_id = os.environ.get("APP_ID")
passwd = os.environ.get("PASSWD")
app_obj_id = os.environ.get("APP_OBJ_ID")
aks_aad_server_id = os.environ.get("AKS_AAD_SERVER_ID")

# Get the cluster info
resource_group = os.environ.get("RG")
cluster_name = os.environ.get("CLUSTER_NAME")
aks_api_server = os.environ.get("AKS_API_SERVER")

container_service_client = ContainerServiceClient(credential, subscription_id)

kubeconfig = container_service_client.managed_clusters.list_cluster_user_credentials(resource_group, cluster_name).kubeconfigs[0]

#print(kubeconfig)

authority_url = 'https://login.microsoftonline.com/'+tenant_id
context = adal.AuthenticationContext(authority_url)
token = context.acquire_token_with_client_credentials(
    resource=aks_aad_server_id,
    client_id=app_id,
    client_secret=passwd
)

# Create a configuration object
aConfiguration = client.Configuration()

#Specify the endpoint of your Kube cluster
aConfiguration.host = "https://"+ aks_api_server + ":443"
aConfiguration.verify_ssl = False
aToken=token["accessToken"]
aConfiguration.api_key = {"authorization": "Bearer " + aToken}
aConfiguration.ssl_ca_cert="ca.crt"

# Create a ApiClient with our config
aApiClient = client.ApiClient(aConfiguration)

# Do calls
v1 = client.CoreV1Api(aApiClient)
print("Listing pods with their IPs:")
ret = v1.list_pod_for_all_namespaces(watch=False)
for i in ret.items:
    print("%s\t%s\t%s" %
          (i.status.pod_ip, i.metadata.namespace, i.metadata.name))


