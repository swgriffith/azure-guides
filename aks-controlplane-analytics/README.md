# Filtering AKS Control Plane Logs with Azure Stream Analytics

## Introduction

While AKS does NOT provide access to the cluster's managed control plane, it does provide access to the control plane component logs via [diagnostic settings](https://learn.microsoft.com/en-us/azure/aks/monitor-aks#aks-control-planeresource-logs). The easiest option to persist and search this data is to send it directly to Azure Log Analytics, however there is a LOT of data in those logs, which makes it cost prohibitive in Log Analytics. Alternatively, you can send all of the data to an Azure Storage Account, but then searching and alerting can be challenging. 

To address the above challenge, on option is to stream the data to Azure Event Hub, which then gives you the option to use stream analytics to filter out events you deem important and then just store the rest for potential future diagnostic needs.

In this walkthrough we'll create an AKS cluster, enable diagnostic logging to Azure Stream Analytics and then demonstrate how to filter out some key records.

## Cluster & Stream Analytics Setup

In this setup, the cluster will be a very basic AKS cluster that will simply have diagnostic settings enabled. 

```bash
# Set some environment variables
RG=LogFilteringLab
LOC=eastus2
CLUSTER_NAME=logfilterlab
NAMESPACE_NAME="akscontrolplane$RANDOM"
EVENT_HUB_NAME="logfilterhub$RANDOM"
DIAGNOSTIC_SETTINGS_NAME="demologfilter"

# Create a resource group
az group create -n $RG -l $LOC

# Create the AKS Cluster
az aks create \
-g $RG \
-n $CLUSTER_NAME \
-c 1

# Get the cluster credentials
az aks get-credentials -g $RG -n $CLUSTER_NAME

# Create an Event Hub Namespace
az eventhubs namespace create --name $NAMESPACE_NAME --resource-group $RG -l $LOC

# Create an event hub
az eventhubs eventhub create --name $EVENT_HUB_NAME --resource-group $RG --namespace-name $NAMESPACE_NAME

AKS_CLUSTER_ID=$(az aks show -g $RG -n $CLUSTER_NAME -o tsv --query id)
EVENT_HUB_NAMESPACE_ID=$(az eventhubs namespace show -g $RG -n $NAMESPACE_NAME -o tsv --query id)

# Apply the diagnostic settings to the AKS cluster to enable Kubernetes audit log shipping
# to our Event Hub
az monitor diagnostic-settings create \
--resource $AKS_CLUSTER_ID \
-n $DIAGNOSTIC_SETTINGS_NAME \
--event-hub $EVENT_HUB_NAME \
--event-hub-rule "${EVENT_HUB_NAMESPACE_ID}/authorizationrules/RootManageSharedAccessKey" \
--logs '[ { "category": "kube-audit", "enabled": true, "retentionPolicy": { "enabled": false, "days": 0 } } ]' 
```

## Setup a test workload to trigger audit log entries

<TBD>

## Stream Analytics

As we'll use Stream Analytics to filter through the log messages for what we want to capture, we'll need ot create a Stream Analytics Job. This Job will take the Event Hub as it's input source, will run a query and will need an output target. This output target can be a number of options, but for the purposes of our test we'll write the filtered records out to a Service Bus Queue, which we can watch in real time.

We have the Event Hub alread, so lets create the Azure Service Bus Queue and then the Stream Analytics Job to tie it all together.

### Create the Service Bus Queue

```bash
SERVICE_BUS_NAMESPACE_NAME=kubecontrolplanelogs
SERVICE_BUS_QUEUE_NAME=kubeaudit

# Create the service bus namespace
az servicebus namespace create --resource-group $RG --name $SERVICE_BUS_NAMESPACE_NAME --location $LOC

# Create the service bus queue
az servicebus queue create --resource-group $RG --namespace-name $SERVICE_BUS_NAMESPACE_NAME --name $SERVICE_BUS_QUEUE_NAME

```

### Stream Analytics Job

For the Stream Analytics Job we'll switch over to the portal, so go ahead and open [https://portal.azure.com](https://portal.azure.com) and navigate to your resource group.

1. Click on the 'Create' button at the top of your resource group:
   
   ![Create](./images/rg-create.jpg)

2. Search for 'Stream Analytics Job'
   
   ![Search](./images/sa-job-search.jpg)

3. Click 'Create' on the Stream Analytics Job search result
   
   ![Search Result](./images/sa-job-search-result.jpg)

4. Leave all defaults, but provide a name under the 'Instance Details' section and then click 'Review + Create'
   
   ![Create Instance](./images/sa-job-create-instance.jpg)

5. After the validation is complete, just click 'Create'. This typically completes very quickly.

6. Click on 'Go to Resource' or navigate back to your resource group and click on the Stream Analytics Job you just created.

7. In the stream analytics job, expand 'Job topology' and then click on 'Inputs' so we can add our Event Hub input
   
   ![Stream Analytics Job - Add Input](./images/sa-job-inputs.jpg)

8. Click on 'Add Input' and select 'Event Hub'
   
   ![Create Input](./images/sa-job-create-input.jpg)

9.  The Event Hub new input pane should auto-populate with your event hub as well as default to creation of a new access policy, but verify that all of the details are correct and then click 'Save'.
    
   ![Event Hub Config Details](./images/sa-event-hub-config.jpg)

10. Now we need to attach the Service Bus we created as the output target, so under 'Job topology' click on 'Outputs'.
    
11. In the 'Outputs' window, click on 'Add output' and select 'Service Bus queue'
    
    ![Add Output](./images/sa-add-output.jpg)

12. Again, it should bring up a window with the queue configuration details already pre-populated, but verify all the details and update as needed and then click 'Save'.
    
    ![Service Bus Config](./images/sa-servicebus-config.jpg)

13. To process the records from AKS we'll need to parse some JSON, so we need to add a function to the Stream Analytics Job to parse JSON. Under 'Job topology' click on 'Functions'.

14. In the functions window, click on 'Add Function' and then select 'Javascript UDF' for Javascript User Defined Function
    
    ![Create Function](./images/sa-create-function.jpg)

15. In the 'Function alias' name the function 'jsonparse' and in the editor window add the following:
    ```javascript
    function main(x) {
    var json = JSON.parse(x);  
    return json;
    }
    ```

    ![Function](./images/sa-javascript-udf.jpg)

16. Click on 'Save' to save the function

17. Now click, under 'Job topology' in the stream analytics job, click on 'Query' to start adding a query. When loaded, the inputs, outputs and functions should pre-populate for you.
    
18. We'll first create a basic query to select all records and ship them to the output target. In the query window past the following, updating the input and output values to match the names of your input and output. The function name should be the same unless you changed it.

    ```sql
    WITH DynamicCTE AS (
    SELECT UDF.jsonparse(individualRecords.ArrayValue.properties.log) AS log
    FROM [logfilterhub28026]
    CROSS APPLY GetArrayElements(records) AS individualRecords
    )
    SELECT *
    INTO [kubeauditlogs]
    FROM DynamicCTE
    ```

19. Click 'Save Query' at the top of the query window

    ![Save Query](./images/sa-save-query.jpg)

20. In the top left of the query window, click on 'Start Job' to kick off the stream analytics job.

21. In the 'Start job' window, leave the start time set to 'Now' and click 'Start'

    ![Start Job](./images/sa-start-job.jpg)
    
22. Click on the 'Overview' tab in the stream analytics job, and refresh every once in a while until the job 'Status' says 'Running'

    ![Job Running](./images/sa-job-status-running.jpg)

23. Navigate back to your Resource Group and then click on your service bus namespace. 

24. Assuming everything worked as expected you should now be seeing a lot of messages coming through the Service Bus Queue

    ![Service Bus Namespace with Data](./images/sb-namespace-live.jpg)

25. Click on the queue at the bottom of the screen to open the Queue level view

26. At the queue level, click on 'Service Bus Explorer' to view the live records

27. To view the records already created' click on 'Peek from start' and then choose a record to view

    ![Live Audit Record](./images/sb-audit-record.jpg)

Great! You should now have a very basic stream analytics job that takes the control plane 'kube-audit' log from an AKS cluster through Event Hub, queries that data and then pushes it to a Service Bus Queue. While this is great, the goal is to filter out some records, so lets move on to that!





