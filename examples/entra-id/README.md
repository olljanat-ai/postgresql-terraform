# Entra ID authenticated database owners

Creates a PostgreSQL flexible server with two databases whose owners are
Microsoft Entra ID identities. No application password is created or stored:
the applications connect with an Entra access token.

| Database  | Owner                              | Authentication |
| --------- | ---------------------------------- | -------------- |
| `orders`  | An Entra group                     | Entra ID       |
| `billing` | A managed identity of the workload | Entra ID       |

`CONNECT` is revoked from `PUBLIC`, so the members of the orders group cannot
connect to `billing` and the billing identity cannot connect to `orders`.

## Usage

The Azure CLI has to be logged in as the identity given in
`entra_administrator_*`, because only an Entra administrator of the server can
create Entra principals inside PostgreSQL.

```bash
az login

export TF_VAR_subscription_id="00000000-0000-0000-0000-000000000000"
export TF_VAR_server_name="psql-example-entra"
export TF_VAR_administrator_password="$(openssl rand -base64 24)"
export TF_VAR_client_ip_address="$(curl -s https://api.ipify.org)"

export TF_VAR_entra_administrator_object_id="$(az ad signed-in-user show --query id -o tsv)"
export TF_VAR_entra_administrator_principal_name="$(az ad signed-in-user show --query userPrincipalName -o tsv)"

export TF_VAR_orders_group_name="sg-orders-db-owners"
export TF_VAR_orders_group_object_id="$(az ad group show --group sg-orders-db-owners --query id -o tsv)"

export TF_VAR_billing_identity_name="id-billing-app"
export TF_VAR_billing_identity_object_id="$(az identity show --name id-billing-app --resource-group rg-billing --query principalId -o tsv)"

terraform init
terraform apply
```

## Connecting as an Entra identity

The access token is the password:

```bash
export PGPASSWORD="$(az account get-access-token \
  --resource https://ossrdbms-aad.database.windows.net \
  --query accessToken -o tsv)"

psql "host=${TF_VAR_server_name}.postgres.database.azure.com \
      user=${TF_VAR_orders_group_name} dbname=orders sslmode=require"
```

A workload using its managed identity requests the same token from the instance
metadata endpoint instead of the Azure CLI.

## Requirements

* Azure CLI (`az`) and `psql` on the machine running Terraform. The module uses
  them to create the Entra principals inside PostgreSQL, because Azure exposes
  that only through the `pgaadauth` SQL functions.
* Network access from that machine to port 5432 of the server.
