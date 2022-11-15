using System;
using System.IO;
using Azure.Core;
using Azure.Identity;
using Azure.Security.KeyVault.Secrets;

class Program
    {
        static void Main(string[] args)
        {
            //Get env variables
            string? secretName = Environment.GetEnvironmentVariable("SECRET_NAME");;
            string? keyVaultName = Environment.GetEnvironmentVariable("KEY_VAULT_NAME");;
            string? versionID = Environment.GetEnvironmentVariable("VERSION_ID");;
            
            //Create Key Vault Client
            var kvUri = String.Format("https://{0}.vault.azure.net", keyVaultName);
            SecretClientOptions options = new SecretClientOptions()
            {
                Retry =
                {
                    Delay= TimeSpan.FromSeconds(2),
                    MaxDelay = TimeSpan.FromSeconds(16),
                    MaxRetries = 5,
                    Mode = RetryMode.Exponential
                 }
            };

            var client = new SecretClient(new Uri(kvUri), new DefaultAzureCredential(),options);

            // Get the secret value in a loop
            while(true){
            Console.WriteLine("Retrieving your secret from " + keyVaultName + ".");
            KeyVaultSecret secret = client.GetSecret(secretName, versionID);
            Console.WriteLine("Your secret is '" + secret.Value + "'.");
            System.Threading.Thread.Sleep(5000);
            }

        }
    }