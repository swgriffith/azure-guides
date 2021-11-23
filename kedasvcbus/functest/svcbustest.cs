using System;
using Microsoft.Azure.WebJobs;
using Microsoft.Azure.WebJobs.Host;
using Microsoft.Extensions.Logging;

namespace functest
{
    public static class svcbustest
    {
        [FunctionName("svcbustest")]
        public static void Run([ServiceBusTrigger("testqueue", Connection = "")]string myQueueItem, ILogger log)
        {
            log.LogInformation($"C# ServiceBus queue trigger function processed message: {myQueueItem}");
            System.Threading.Thread.Sleep(100);
        }
    }
}
