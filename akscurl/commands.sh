curl --location --request GET 'https://login.microsoftonline.com/<AAD TENANT>/oauth2/v2.0/token' \
--header 'Content-Type: application/x-www-form-urlencoded' \
--data-urlencode 'grant_type=client_credentials' \
--data-urlencode 'client_id=<ClientID>' \
--data-urlencode 'client_secret=<ClientSecret>' \
--data-urlencode 'scope=<Scope>>'

curl --location --request GET 'https://<AKS API SERVER>/api/v1/namespaces' \
--header 'Authorization: Bearer <Insert JWT>'

