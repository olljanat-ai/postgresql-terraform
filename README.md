# postgresql-terraform

Terraform configuration that creates an Azure Database for PostgreSQL flexible
server and a list of databases on it. Every database gets its own owner, which
has full permissions on that database and no access to the other ones.

An owner is a PostgreSQL role with a username and a generated password.

The generated owner passwords are written into an Azure Key Vault, so that the
applications using the databases have somewhere to read them from that is not
the Terraform state.

## Layout

Everything lives in the root module. An environment is nothing but a variable
file under [`environments/`](environments):

```
main.tf, variables.tf, outputs.tf, versions.tf   the configuration
environments/prototype.tfvars                    the prototype environment
```

## Usage

```bash
az login

export TF_VAR_administrator_password="$(openssl rand -base64 24)"

terraform init
terraform apply -var-file=environments/prototype.tfvars
```

Edit `environments/prototype.tfvars` first: it ships with a placeholder
subscription and address, and it holds no secrets. Adding another environment
means adding another `.tfvars` file next to it, nothing else.

Read the generated owner passwords afterwards, either from the Key Vault:

```bash
az keyvault secret show \
  --vault-name "$(terraform output -raw key_vault_name)" \
  --name orders-owner --query value -o tsv
```

or from the state:

```bash
terraform output -json owner_passwords
```

### The prototype environment

| Database    | Owner           |
| ----------- | --------------- |
| `orders`    | `orders_owner`  |
| `billing`   | `billing_app`   |
| `analytics` | `analytics_owner` |
| `reporting` | `reporting_owner` |

### Connecting

```bash
PGPASSWORD="$(az keyvault secret show \
  --vault-name "$(terraform output -raw key_vault_name)" \
  --name orders-owner --query value -o tsv)" \
  psql "host=$(terraform output -raw fqdn) user=orders_owner dbname=orders sslmode=require"
```

## How the isolation works

* Each database is created with `CREATE DATABASE ... OWNER <its own role>`. From
  PostgreSQL 15 onwards the `public` schema is owned by `pg_database_owner` and
  `PUBLIC` no longer has `CREATE` on it, so the owner has full rights inside its
  database without any extra grants and nobody else has any. `postgresql_version`
  is therefore required to be 15 or newer.
* `CONNECT` is revoked from `PUBLIC` on every managed database
  (`revoke_public_connect`, on by default). Without it every role on the server,
  including the owners of the other databases, could connect to all of them.
* Only the server administrator, which Terraform itself uses, can reach every
  database.

## Where the passwords are kept

Setting `key_vault_name` creates a Key Vault into the same resource group and
writes one secret per database owner into it, named after the owner role with
the underscores turned into dashes, because a Key Vault secret name may only
carry letters, digits and dashes:

| Database  | Owner role     | Secret         |
| --------- | -------------- | -------------- |
| `orders`  | `orders_owner` | `orders-owner` |
| `billing` | `billing_app`  | `billing-app`  |

The administrator password goes in as well, under `administrator_login`
(`pgadmin` by default), unless `key_vault_store_administrator_password` is turned
off. `terraform output owner_password_secrets` maps every database to the name of
its secret.

The vault uses Azure RBAC rather than the legacy access policies, and creating a
vault grants no access to the secrets inside it. Terraform therefore assigns
itself the **Key Vault Secrets Officer** role on the vault, which requires the
identity it runs as to be allowed to create role assignments, so Owner or User
Access Administrator on the resource group or the subscription. When that access
is granted outside of this configuration instead, set
`key_vault_grant_deployer_access = false`. A fresh role assignment takes a while
to reach the data plane of the vault, so the configuration waits a minute after
creating it before writing the first secret.

Grant the applications reading the passwords the **Key Vault Secrets User** role
on the vault, or on the individual secrets, outside of this configuration.

Leaving `key_vault_name` unset skips the vault entirely and leaves the passwords
in the state and in the `owner_passwords` output only.

## Requirements

| Name                                                                               | Version  |
| ---------------------------------------------------------------------------------- | -------- |
| terraform                                                                          | >= 1.5.0 |
| [hashicorp/azurerm](https://registry.terraform.io/providers/hashicorp/azurerm)      | >= 4.0   |
| [cyrilgdn/postgresql](https://registry.terraform.io/providers/cyrilgdn/postgresql)  | >= 1.22  |
| [hashicorp/random](https://registry.terraform.io/providers/hashicorp/random)        | >= 3.5   |
| [hashicorp/time](https://registry.terraform.io/providers/hashicorp/time)            | >= 0.9   |

Terraform manages the databases and the roles over port 5432, so the machine it
runs from needs network access to the server and a firewall rule allowing its
address.

## Microsoft Entra ID

Not supported. The server is created with Entra authentication turned off and
password authentication on, and every database owner is a password
authenticated role. Entra ID owners were part of an earlier revision and were
dropped because the credentials never worked reliably: Azure only exposes the
creation of Entra principals through the `pgaadauth` SQL functions, those may
only be called by an Entra administrator of the server, and only a token of the
identity the Azure CLI is signed in as can be requested, which pinned the
Terraform runner to that one identity.

## Inputs

| Name                            | Description                                                                             | Type           | Default             | Required |
| ------------------------------- | --------------------------------------------------------------------------------------- | -------------- | ------------------- | :------: |
| `subscription_id`               | Azure subscription the resources are created into.                                      | `string`       | n/a                 |   yes    |
| `resource_group_name`           | Resource group, created by this configuration.                                          | `string`       | n/a                 |   yes    |
| `server_name`                   | Name of the flexible server.                                                            | `string`       | n/a                 |   yes    |
| `administrator_password`        | Password of the built-in administrator. Pass as `TF_VAR_administrator_password`.        | `string`       | n/a                 |   yes    |
| `databases`                     | Databases to create and the name of their owner role. See below.                        | `list(object)` | `[]`                |    no    |
| `location`                      | Azure region.                                                                           | `string`       | `"swedencentral"`   |    no    |
| `postgresql_version`            | Major PostgreSQL version, 15 or newer.                                                  | `string`       | `"15"`              |    no    |
| `sku_name`                      | Server SKU.                                                                             | `string`       | `"B_Standard_B2s"`  |    no    |
| `zone`                          | Availability zone the server is placed in.                                              | `string`       | `"1"`               |    no    |
| `storage_mb`                    | Storage in megabytes.                                                                   | `number`       | `32768`             |    no    |
| `backup_retention_days`         | Days backups are kept.                                                                  | `number`       | `7`                 |    no    |
| `administrator_login`           | Login of the built-in administrator.                                                    | `string`       | `"pgadmin"`         |    no    |
| `public_network_access_enabled` | Whether the server is reachable from the internet.                                      | `bool`         | `true`              |    no    |
| `firewall_rules`                | Firewall rules, keyed by rule name.                                                     | `map(object)`  | `{}`                |    no    |
| `revoke_public_connect`         | Revoke `CONNECT` from `PUBLIC` on the managed databases.                                | `bool`         | `true`              |    no    |
| `key_vault_name`                | Key Vault the generated passwords are written to. Unset means no vault.                 | `string`       | `null`              |    no    |
| `key_vault_sku_name`            | SKU of the vault, `standard` or `premium`.                                              | `string`       | `"standard"`        |    no    |
| `key_vault_soft_delete_retention_days` | Days a deleted vault can still be recovered, 7 to 90.                            | `number`       | `7`                 |    no    |
| `key_vault_purge_protection_enabled` | Keep a deleted vault for the whole retention period. Cannot be undone.             | `bool`         | `false`             |    no    |
| `key_vault_public_network_access_enabled` | Whether the vault is reachable from the internet.                             | `bool`         | `true`              |    no    |
| `key_vault_grant_deployer_access` | Assign Key Vault Secrets Officer on the vault to the identity Terraform runs as.       | `bool`         | `true`              |    no    |
| `key_vault_store_administrator_password` | Also store `administrator_password` in the vault.                               | `bool`         | `true`              |    no    |
| `tags`                          | Tags applied to the resource group, the server and the vault.                           | `map(string)`  | `{}`                |    no    |

### `databases`

| Field            | Description                            | Default          |
| ---------------- | -------------------------------------- | ---------------- |
| `name`           | Database name.                         | n/a              |
| `charset`        | Database encoding.                     | `"UTF8"`         |
| `collation`      | Database collation.                    | `"en_US.utf8"`   |
| `owner_username` | Name of the owner role.                | `"<name>_owner"` |

## Outputs

| Name                  | Description                                                                 |
| --------------------- | --------------------------------------------------------------------------- |
| `resource_group_name` | Name of the resource group.                                                 |
| `server_id`           | Resource id of the server.                                                  |
| `server_name`         | Name of the server.                                                         |
| `fqdn`                | Host name of the server.                                                    |
| `administrator_login` | Login of the built-in administrator.                                        |
| `databases`           | Databases and their owner role.                                             |
| `owner_passwords`     | Generated owner passwords, per database (sensitive).                        |
| `key_vault_id`        | Resource id of the Key Vault, `null` when no vault is created.              |
| `key_vault_name`      | Name of the Key Vault, `null` when no vault is created.                     |
| `key_vault_uri`       | Data plane URI of the Key Vault, `null` when no vault is created.           |
| `owner_password_secrets` | Name of the secret holding each owner password, per database.            |
| `administrator_password_secret` | Name of the secret holding the administrator password.            |

## Notes

* Azure offers a different set of PostgreSQL versions per SKU and region. When
  the requested combination is not offered, the create fails with
  `ParameterOutOfRange: The value of the 'Version' should be in: []`, an empty
  list rather than the versions that would work. List what a region actually has
  with `az postgres flexible-server list-skus --location <region> --output
  table`, and pin `location`, `sku_name` and `postgresql_version` in the
  environment file.
* Owner passwords are stored in the Terraform state as well, the Key Vault does
  not change that. Keep the state in a backend that encrypts it.
* Rotating an owner password means tainting its `random_password.owner` entry;
  the new value is written over the existing secret as a new version, and the
  previous versions stay in the vault until the secret is deleted.
* With `key_vault_purge_protection_enabled = false`, which is the default, a
  `terraform destroy` also purges the vault, so its name is free again right
  away. With purge protection on, the vault is only soft deleted and its name
  stays reserved for `key_vault_soft_delete_retention_days`.
