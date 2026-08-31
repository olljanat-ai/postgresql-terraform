# postgresql-terraform

Terraform configuration that creates an Azure Database for PostgreSQL flexible
server and a list of databases on it. Every database gets its own owner, which
has full permissions on that database and no access to the other ones.

An owner is either

* a PostgreSQL role with a username and a generated password, or
* a Microsoft Entra ID identity (user, group or managed identity), which
  connects with an Entra access token instead of a password.

The two cases can be mixed on the same server, the choice is made per database.

## Layout

Everything lives in the root module. An environment is nothing but a variable
file under [`environments/`](environments):

```
main.tf, variables.tf, outputs.tf, versions.tf   the configuration
environments/prototype.tfvars                    the prototype environment
```

## Usage

The Azure CLI has to be logged in as the identity given in
`entra_administrator`, because only an Entra administrator of the server can
create Entra principals inside PostgreSQL.

```bash
az login

export TF_VAR_administrator_password="$(openssl rand -base64 24)"

terraform init
terraform apply -var-file=environments/prototype.tfvars
```

Edit `environments/prototype.tfvars` first: it ships with placeholder
subscription, address and Entra object ids, and it holds no secrets. Adding
another environment means adding another `.tfvars` file next to it, nothing
else.

Read the generated owner passwords afterwards:

```bash
terraform output -json owner_passwords
```

### The prototype environment

| Database    | Owner                | Authentication      |
| ----------- | -------------------- | ------------------- |
| `orders`    | `orders_owner`       | username + password |
| `billing`   | `billing_app`        | username + password |
| `analytics` | An Entra ID group    | Entra ID            |
| `reporting` | A managed identity   | Entra ID            |

### Connecting

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

## Requirements

| Name                                                                               | Version  |
| ---------------------------------------------------------------------------------- | -------- |
| terraform                                                                          | >= 1.5.0 |
| [hashicorp/azurerm](https://registry.terraform.io/providers/hashicorp/azurerm)      | >= 4.0   |
| [cyrilgdn/postgresql](https://registry.terraform.io/providers/cyrilgdn/postgresql)  | >= 1.22  |
| [hashicorp/random](https://registry.terraform.io/providers/hashicorp/random)        | >= 3.5   |

Terraform manages the databases and the roles over port 5432, so the machine it
runs from needs network access to the server and a firewall rule allowing its
address.

Databases owned by an Entra ID identity additionally need `psql` and the Azure
CLI on that machine. Azure only exposes the creation of Entra principals through
the `pgaadauth` SQL functions, and those may only be called by an Entra
administrator of the server, so the configuration calls them over `psql` with an
access token from `az account get-access-token`. An environment without
`entra_principal` databases needs neither tool.

## Inputs

| Name                            | Description                                                                             | Type           | Default             | Required |
| ------------------------------- | --------------------------------------------------------------------------------------- | -------------- | ------------------- | :------: |
| `subscription_id`               | Azure subscription the resources are created into.                                      | `string`       | n/a                 |   yes    |
| `resource_group_name`           | Resource group, created by this configuration.                                          | `string`       | n/a                 |   yes    |
| `server_name`                   | Name of the flexible server.                                                            | `string`       | n/a                 |   yes    |
| `administrator_password`        | Password of the built-in administrator. Pass as `TF_VAR_administrator_password`.        | `string`       | n/a                 |   yes    |
| `databases`                     | Databases to create and how their owner authenticates. See below.                       | `list(object)` | `[]`                |    no    |
| `entra_administrator`           | Entra principal that becomes an administrator of the server. Required for Entra owners. | `object`       | `null`              |    no    |
| `location`                      | Azure region.                                                                           | `string`       | `"swedencentral"`   |    no    |
| `postgresql_version`            | Major PostgreSQL version, 15 or newer.                                                  | `string`       | `"15"`              |    no    |
| `sku_name`                      | Server SKU.                                                                             | `string`       | `"B_Standard_B2s"`  |    no    |
| `storage_mb`                    | Storage in megabytes.                                                                   | `number`       | `32768`             |    no    |
| `backup_retention_days`         | Days backups are kept.                                                                  | `number`       | `7`                 |    no    |
| `administrator_login`           | Login of the built-in administrator.                                                    | `string`       | `"pgadmin"`         |    no    |
| `public_network_access_enabled` | Whether the server is reachable from the internet.                                      | `bool`         | `true`              |    no    |
| `firewall_rules`                | Firewall rules, keyed by rule name.                                                     | `map(object)`  | `{}`                |    no    |
| `revoke_public_connect`         | Revoke `CONNECT` from `PUBLIC` on the managed databases.                                | `bool`         | `true`              |    no    |
| `tags`                          | Tags applied to the resource group and the server.                                      | `map(string)`  | `{}`                |    no    |

### `databases`

| Field                       | Description                                                                               | Default          |
| --------------------------- | ----------------------------------------------------------------------------------------- | ---------------- |
| `name`                      | Database name.                                                                            | n/a              |
| `charset`                   | Database encoding.                                                                        | `"UTF8"`         |
| `collation`                 | Database collation.                                                                       | `"en_US.utf8"`   |
| `owner_username`            | Name of the password authenticated owner role.                                            | `"<name>_owner"` |
| `entra_principal`           | Set this to make an Entra ID identity the owner instead of a password authenticated role. | `null`           |
| `entra_principal.name`      | User principal name of a user, or display name of a group or a managed identity.          | n/a              |
| `entra_principal.object_id` | Entra object id of the identity.                                                          | n/a              |
| `entra_principal.type`      | `user`, `group` or `service`.                                                             | `"user"`         |

## Outputs

| Name                  | Description                                                                 |
| --------------------- | --------------------------------------------------------------------------- |
| `resource_group_name` | Name of the resource group.                                                 |
| `server_id`           | Resource id of the server.                                                  |
| `server_name`         | Name of the server.                                                         |
| `fqdn`                | Host name of the server.                                                    |
| `administrator_login` | Login of the built-in administrator.                                        |
| `databases`           | Databases, their owner and how that owner authenticates.                    |
| `owner_passwords`     | Generated owner passwords, per database, for the password case (sensitive). |

## Notes

* Azure offers a different set of PostgreSQL versions per SKU and region. When
  the requested combination is not offered, the create fails with
  `ParameterOutOfRange: The value of the 'Version' should be in: []`, an empty
  list rather than the versions that would work. List what a region actually has
  with `az postgres flexible-server list-skus --location <region> --output
  table`, and pin `location`, `sku_name` and `postgresql_version` in the
  environment file.
* An Entra principal is created inside PostgreSQL when the database is first
  created and is not removed when the database is destroyed. Renaming an
  `entra_principal` creates the new principal and leaves the old one in place;
  drop it with `DROP ROLE` if it is no longer wanted.
* Owner passwords are stored in the Terraform state. Keep the state in a backend
  that encrypts it, or use Entra ID owners, which have no password at all.
