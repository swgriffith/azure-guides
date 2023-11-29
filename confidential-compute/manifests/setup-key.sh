#!/bin/bash

# --------------------------------------------------------------------------------------------
# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the MIT License. See License.txt in the project root for license information.
# --------------------------------------------------------------------------------------------


set -e

# This script creates a RSA key in MHSM with a release policy, then downloads
# the public key and saves the key info

if [ $# -ne 2 ] ; then
	echo "Usage: $0 <KEY_NAME> <AZURE_AKV_RESOURCE_ENDPOINT>"
	exit 1
fi

https="https://"
http="http://"
KEY_NAME=$1

# if https://, http:// and trailing / exists, remove them from url 
AZURE_AKV_RESOURCE_ENDPOINT=${2#$https}
AZURE_AKV_RESOURCE_ENDPOINT=${AZURE_AKV_RESOURCE_ENDPOINT#$http}
AZURE_AKV_RESOURCE_ENDPOINT=${AZURE_AKV_RESOURCE_ENDPOINT%%/*}


MAA_ENDPOINT=${MAA_ENDPOINT#$https}
MAA_ENDPOINT=${MAA_ENDPOINT#$http}
MAA_ENDPOINT=${MAA_ENDPOINT%%/*}

key_vault_name=$(echo "$AZURE_AKV_RESOURCE_ENDPOINT" | cut -d. -f1)
echo "Key vault name is ${key_vault_name}"

if [[ "$AZURE_AKV_RESOURCE_ENDPOINT" == *".vault.azure.net" ]]; then
	if [[ $(az keyvault list -o json| grep "Microsoft.KeyVault/vaults/${key_vault_name}" ) ]] 2>/dev/null; then
		echo "AKV endpoint OK"
	else
		echo "Azure akv resource endpoint doesn't exist. Please refer to documentation instructions to set it up first:"
		exit 1
	fi
elif [[ "$AZURE_AKV_RESOURCE_ENDPOINT" == *".managedhsm.azure.net" ]]; then
	if [[ $(az keyvault list -o json| grep "Microsoft.KeyVault/managedHSMs/${key_vault_name}" ) ]] 2>/dev/null; then
		echo "AKV endpoint OK"
	else
		echo "Azure akv resource endpoint doesn't exist. Please refer to documentation instructions to set it up first:"
		exit 1
	fi
fi

if [[ -z "${MAA_ENDPOINT}" ]]; then
	echo "Error: Env MAA_ENDPOINT is not set. Please set up your own MAA instance or select from a region where MAA is offered (e.g. sharedeus.eus.attest.azure.net):"
	echo ""
	echo "https://azure.microsoft.com/en-us/explore/global-infrastructure/products-by-region/?products=azure-attestation"
	exit 1
fi

if [[ -z "${MANAGED_IDENTITY}" ]]; then
	echo "Error: Env MANAGED_IDENTITY is not set. Please assign principal ID of the managed identity that will have read access to the key. To create a managed identity:"
	echo "az identity create -g <resource-group-name> -n <identity-name>"
	exit 1
fi

policy_file_name="${KEY_NAME}-release-policy.json"

echo { \"anyOf\":[ { \"authority\":\"https://${MAA_ENDPOINT}\", \"allOf\":[ > ${policy_file_name}
echo '{"claim":"x-ms-attestation-type", "equals":"sevsnpvm"},' >> ${policy_file_name}

if [[ -z "${WORKLOAD_MEASUREMENT}" ]]; then
	echo "Warning: Env WORKLOAD_MEASUREMENT is not set. Set this to condition releasing your key on your security policy matching the expected value.  Recommended for production workloads."
else
	echo {\"claim\":\"x-ms-sevsnpvm-hostdata\", \"equals\":\"${WORKLOAD_MEASUREMENT}\"}, >> ${policy_file_name}
fi


echo {\"claim\":\"x-ms-compliance-status\", \"equals\":\"azure-signed-katacc-uvm\"}, >> ${policy_file_name}
echo {\"claim\":\"x-ms-sevsnpvm-is-debuggable\", \"equals\":\"false\"}, >> ${policy_file_name}

echo '] } ], "version":"1.0.0" }' >> ${policy_file_name}
echo "......Generated key release policy ${policy_file_name}"

# Create RSA key
az keyvault key create --id https://$AZURE_AKV_RESOURCE_ENDPOINT/keys/${KEY_NAME} --ops wrapKey unwrapkey encrypt decrypt --kty RSA-HSM --size 3072 --exportable --policy ${policy_file_name}
echo "......Created RSA key in ${AZURE_AKV_RESOURCE_ENDPOINT}"


# # Download the public key
public_key_file=${KEY_NAME}-pub.pem
rm -f ${public_key_file}

if [[ "$AZURE_AKV_RESOURCE_ENDPOINT" == *".vault.azure.net" ]]; then
    az keyvault key download --vault-name ${key_vault_name} -n ${KEY_NAME} -f ${public_key_file}
	echo "......Downloaded the public key to ${public_key_file}"
elif [[ "$AZURE_AKV_RESOURCE_ENDPOINT" == *".managedhsm.azure.net" ]]; then

    az keyvault key download --hsm-name ${key_vault_name} -n ${KEY_NAME} -f ${public_key_file}
	echo "......Downloaded the public key to ${public_key_file}"
fi

# generate key info file
key_info_file=${KEY_NAME}-info.json
echo {  > ${key_info_file}
echo \"public_key_path\": \"${public_key_file}\", >> ${key_info_file}
echo \"kms_endpoint\": \"$AZURE_AKV_RESOURCE_ENDPOINT\", >> ${key_info_file}
echo \"attester_endpoint\": \"${MAA_ENDPOINT}\" >> ${key_info_file}
echo }  >> ${key_info_file}
echo "......Generated key info file ${key_info_file}"
echo "......Key setup successful!"
