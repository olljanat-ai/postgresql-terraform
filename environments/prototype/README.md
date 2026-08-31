# Prototype environment

A single PostgreSQL flexible server carrying all four kinds of database the
root module supports. Each database has its own owner with full permissions on
it, and `CONNECT` is revoked from `PUBLIC`, so none of the owners can reach the
other databases.

| Database    | Owner                    | Authentication      |
| ----------- | ------------------------ | ------------------- |
| `orders`    | `orders_owner`           | username + password |
| `billing`   | `billing_app`            | username + password |
| `analytics` | An Entra ID group        | Entra ID            |
| `reporting` | A managed identity       | Entra ID            |

## Usage

The Azure CLI has to be logged in as the identity given in
`entra_administrator_*`, because only an Entra administrator of the server can
create Entra principals inside PostgreSQL.

```bash
az login

cp terraform.tfvars.example terraform.tfvars   # then fill it in
export TF_VAR_administrator_password="$(openssl rand -base64 24)"

terraform init
terraform apply
```

Read the generated owner passwords afterwards:

```bash
terraform output -json owner_passwords
```

## Connecting

As a password authenticated owner:

```bash
PGPASSWORD="$(terraform output -json owner_passwords | jq -r .orders)" \
  psql "host=$(terraform output -raw fqdn) user=orders_owner dbname=orders sslmode=require"
```

As an Entra ID identity, where the access token is the password:

```bash
export PGPASSWORD="$(az account get-access-token \
  --resource https://ossrdbms-aad.database.windows.net \
  --query accessToken -o tsv)"

psql "host=$(terraform output -raw fqdn) user=sg-analytics-db-owners dbname=analytics sslmode=require"
```

A workload using its managed identity requests the same token from the instance
metadata endpoint instead of the Azure CLI.

## Requirements

* Azure CLI (`az`) and `psql` on the machine running Terraform. The module uses
  them to create the Entra principals inside PostgreSQL, because Azure exposes
  that only through the `pgaadauth` SQL functions.
* Network access from that machine to port 5432 of the server.

Drop the two `entra_principal` databases from `main.tf` and the whole
environment applies with the Azure CLI alone.
