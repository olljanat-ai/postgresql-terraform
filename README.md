# postgresql-terraform

Terraform configuration that creates an Azure Database for PostgreSQL flexible
server and a list of databases on it. Every database gets its own owner, which
has full permissions on that database and no access to the other ones.

An owner is either

* a PostgreSQL role with a username and a generated password, or
* a Microsoft Entra ID identity (user, group or managed identity), which
  connects with an Entra access token instead of a password.

The two cases can be mixed on the same server, the choice is made per database.
A database can also carry both at once: `owner_members` adds further login roles
to it, each authenticating its own way, which is what lets an application move
from a username and a password to an Entra workload identity while both keep
working. See [More than one login per database](#more-than-one-login-per-database).

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

Edit `environments/prototype.tfvars` first: it ships with placeholder
subscription, address and Entra object ids, and it holds no secrets. Adding
another environment means adding another `.tfvars` file next to it, nothing
else.

Only the Azure credentials are needed on the machine Terraform runs from; the
Entra owners are created over the same PostgreSQL connection as everything else,
so neither `psql` nor the Azure CLI has to be installed for them.

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

| Database    | Owner              | Authentication      |
| ----------- | ------------------ | ------------------- |
| `orders`    | `orders_owner`     | username + password |
| `billing`   | `billing_app`      | username + password |
| `analytics` | An Entra ID group  | Entra ID            |
| `reporting` | A managed identity | Entra ID            |

### Connecting

As a password authenticated owner:

```bash
PGPASSWORD="$(az keyvault secret show \
  --vault-name "$(terraform output -raw key_vault_name)" \
  --name orders-owner --query value -o tsv)" \
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
* An `owner_members` role is granted the owner role and switches to it at login
  (`ALTER ROLE ... SET ROLE`), so it has the rights of the owner on that one
  database and nothing anywhere else, and everything it creates is owned by the
  owner role rather than by itself.

## More than one login per database

A PostgreSQL database has exactly one owner: `pg_database.datdba` holds a single
role. Several identities reach one database by being **members of that owner
role**, which is what `owner_members` creates. A member passes every ownership
check, because PostgreSQL tests ownership with `has_privs_of_role(current_user,
owner)` rather than `current_user = owner`, and that includes the
`pg_database_owner` membership that carries the `public` schema.

Each member authenticates on its own, so the same database can be reached with a
username and a password and with an Entra workload identity at the same time:

```hcl
databases = [
  {
    name           = "billing"
    owner_username = "billing_app"

    owner_members = [
      {
        name = "id-billing-app"
        entra_principal = {
          object_id = "831b3ba3-03cc-4270-b7e6-5905683c847f"
          type      = "service"
        }
      },
    ]
  },
]
```

That is:

```sql
CREATE ROLE "id-billing-app" LOGIN;
SECURITY LABEL FOR "pgaadauth" ON ROLE "id-billing-app"
  IS 'aadauth,oid=831b3ba3-03cc-4270-b7e6-5905683c847f,type=service';
GRANT billing_app TO "id-billing-app";
ALTER ROLE "id-billing-app" SET ROLE billing_app;
```

The database itself does not change hands, so nothing has to be reassigned and
the application using `billing_app` and its password keeps working untouched.

`terraform output login_roles` lists every role that can sign in, which database
it reaches, how it authenticates and where its password is:

```json
{
  "billing_app":     { "database": "billing", "membership": "owner",  "authentication": "password", "secret": "billing-app" },
  "id-billing-app":  { "database": "billing", "membership": "member", "authentication": "entra-id", "secret": null }
}
```

### Moving an application to an Entra workload identity

1. Add the workload identity to `owner_members` as above and apply. Both logins
   now work, and the application is unchanged.
2. The application team switches its connection to the identity: user
   `id-billing-app`, and an access token from the instance metadata endpoint as
   the password. No password is involved and nothing has to be read from the
   Key Vault.
3. Once nothing signs in as `billing_app` any more, set `owner_login = false` on
   the database and apply. The owner role keeps owning the database and its
   objects, but it can no longer sign in, and its generated password and its
   Key Vault secret are gone.

```hcl
{
  name           = "billing"
  owner_username = "billing_app"
  owner_login    = false

  owner_members = [
    {
      name            = "id-billing-app"
      entra_principal = { object_id = "831b3ba3-...", type = "service" }
    },
  ]
}
```

Step 3 is reversible: setting `owner_login` back to true generates a new
password and writes it to the vault again. The old secret is soft deleted rather
than removed though, so on a vault with `key_vault_purge_protection_enabled` the
name stays reserved until the retention period runs out, and the write fails
until it is recovered or purged.

### Objects created before the members existed

`assume_role` only affects what a member creates from now on. Tables that the
owner role itself created are already owned by the owner role, which is what
every member switches to, so they need nothing. But if a database was reaching
this configuration from somewhere else and its objects are owned by some other
role, hand them over once, as that role or as the administrator:

```sql
REASSIGN OWNED BY <old role> TO billing_app;
```

Terraform does not do this: it is a one-off migration of data that already
exists, not part of the desired state.

## Where the passwords are kept

Setting `key_vault_name` creates a Key Vault into the same resource group and
writes one secret per password authenticated database owner into it, named after
the owner role with the underscores turned into dashes, because a Key Vault
secret name may only carry letters, digits and dashes:

| Database  | Owner role     | Secret         |
| --------- | -------------- | -------------- |
| `orders`  | `orders_owner` | `orders-owner` |
| `billing` | `billing_app`  | `billing-app`  |

The administrator password goes in as well, under `administrator_login`
(`pgadmin` by default), unless `key_vault_store_administrator_password` is turned
off. `terraform output owner_password_secrets` maps every database to the name of
its secret. Databases owned by an Entra ID identity have no password and no
secret.

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
| [cyrilgdn/postgresql](https://registry.terraform.io/providers/cyrilgdn/postgresql)  | >= 1.25  |
| [hashicorp/random](https://registry.terraform.io/providers/hashicorp/random)        | >= 3.5   |
| [hashicorp/time](https://registry.terraform.io/providers/hashicorp/time)            | >= 0.9   |

Terraform manages the databases and the roles over port 5432, so the machine it
runs from needs network access to the server and a firewall rule allowing its
address.

## Microsoft Entra ID

Setting `entra_principal` on a database makes an Entra ID identity its owner.
Setting `entra_administrator` turns Entra authentication on for the server and
makes that principal an Entra administrator of it, which is required for any
Entra owner.

### How the principals are created

An Entra principal inside PostgreSQL is an ordinary role carrying a security
label of the `pgaadauth` label provider, which maps it to an Entra object:

```sql
CREATE ROLE "sg-analytics-db-owners" LOGIN;
SECURITY LABEL FOR "pgaadauth" ON ROLE "sg-analytics-db-owners"
  IS 'aadauth,oid=f51ee4ed-6c2d-42ee-9ba7-a08814b047ec,type=group';
```

That is all `pgaadauth_create_principal_with_oid()` does, and both statements
are plain resources here: `postgresql_role` and `postgresql_security_label`.
Azure documents the label as [the way to enable Entra authentication for an
existing role][ms-label], and the provider has carried
[`postgresql_security_label`][tf-label] since 1.25, with the `pgaadauth` case as
its example. An earlier revision of this configuration instead called
`pgaadauth_create_principal_with_oid()` over `psql` from a `local-exec`
provisioner, which needed `psql` and the Azure CLI on the machine Terraform ran
from and could neither read back nor destroy what it had created.

Only an Entra administrator may write the label, so it is written over a second
`postgresql` provider that authenticates with an Entra access token
(`azure_identity_auth`, [documented in the provider][tf-azure]). The provider
acquires the token itself, from the same credential chain the `azurerm` provider
uses. Everything else — the role, the database, the grants — is created by the
built-in administrator over the primary connection, exactly like a password
owner.

[ms-label]: https://learn.microsoft.com/en-us/azure/postgresql/security/security-manage-entra-users
[tf-label]: https://registry.terraform.io/providers/cyrilgdn/postgresql/latest/docs/resources/postgresql_security_label
[tf-azure]: https://registry.terraform.io/providers/cyrilgdn/postgresql/latest/docs#azure

### What `entra_administrator` has to be

The identity Terraform runs as, or a group that identity is a member of. The
token the provider acquires is always a token of the identity Terraform runs as,
and PostgreSQL only accepts it for a role mapped to that identity.

A group is the easier of the two. It survives a change of the identity running
Terraform, and it sidesteps the token type check: PostgreSQL refuses a token
whose type does not match the role it is presented for, so pointing
`entra_administrator` at a *user* while running as a service principal fails
with

```
FATAL: Microsoft Entra user token for role "..." is neither an
AAD_AUTH_TOKENTYPE_APP_USER or an AAD_AUTH_TOKENTYPE_APP_OBO token.
```

Fill the input in from the identity you actually run as — `az ad signed-in-user
show` for a user, `az ad sp show` for a service principal, whose
`principal_name` is its display name rather than its application id.
`environments/prototype.tfvars` carries all three command pairs.

### Checking the result

```sql
SELECT * FROM pg_catalog.pgaadauth_list_principals(false);
```

An environment without any `entra_principal` database leaves Entra
authentication turned off on the server, creates no administrator and never
acquires a token, so it needs no Entra identity that can sign in to PostgreSQL.

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
| `owner_login`               | Whether the owner role itself signs in. `false` leaves it holding the ownership only.     | `true`           |
| `owner_members`             | Further login roles granted the owner role, so that one database has several logins.      | `[]`             |

### `databases[*].owner_members`

| Field                       | Description                                                                               | Default  |
| --------------------------- | ----------------------------------------------------------------------------------------- | -------- |
| `name`                      | Name of the role. For an Entra member this is the name Entra ID resolves at sign in.      | n/a      |
| `entra_principal`           | Set this to make the member an Entra ID identity instead of a password authenticated role. | `null`   |
| `entra_principal.object_id` | Entra object id of the identity.                                                          | n/a      |
| `entra_principal.type`      | `user`, `group` or `service`.                                                             | `"user"` |

### `entra_administrator`

| Field            | Description                                                                      | Default  |
| ---------------- | -------------------------------------------------------------------------------- | -------- |
| `object_id`      | Entra object id of the principal.                                                | n/a      |
| `principal_name` | User principal name of a user, or display name of a group or service principal.  | n/a      |
| `principal_type` | `User`, `Group` or `ServicePrincipal`.                                           | `"User"` |

## Outputs

| Name                  | Description                                                                 |
| --------------------- | --------------------------------------------------------------------------- |
| `resource_group_name` | Name of the resource group.                                                 |
| `server_id`           | Resource id of the server.                                                  |
| `server_name`         | Name of the server.                                                         |
| `fqdn`                | Host name of the server.                                                    |
| `administrator_login` | Login of the built-in administrator.                                        |
| `databases`           | Databases, their owner, how that owner authenticates and its members.       |
| `login_roles`         | Every role that can sign in, per role name: database, membership, authentication and secret. |
| `owner_passwords`     | Generated owner passwords, per database, for the password case (sensitive). |
| `member_passwords`    | Generated `owner_members` passwords, per role name (sensitive).             |
| `key_vault_id`        | Resource id of the Key Vault, `null` when no vault is created.              |
| `key_vault_name`      | Name of the Key Vault, `null` when no vault is created.                     |
| `key_vault_uri`       | Data plane URI of the Key Vault, `null` when no vault is created.           |
| `owner_password_secrets` | Name of the secret holding each owner password, per database.            |
| `member_password_secrets` | Name of the secret holding each member password, per role name.         |
| `administrator_password_secret` | Name of the secret holding the administrator password.            |

## Notes

* Azure offers a different set of PostgreSQL versions per SKU and region. When
  the requested combination is not offered, the create fails with
  `ParameterOutOfRange: The value of the 'Version' should be in: []`, an empty
  list rather than the versions that would work. List what a region actually has
  with `az postgres flexible-server list-skus --location <region> --output
  table`, and pin `location`, `sku_name` and `postgresql_version` in the
  environment file.
* Turning Entra authentication on or off on an existing server restarts it, so
  adding the first `entra_principal` database to an environment that had none
  causes a short outage.
* An Entra owner is a managed role here, so renaming an `entra_principal`
  replaces the role and `terraform destroy` drops it, unlike the principals the
  earlier `pgaadauth_create_principal_with_oid()` revision left behind.
* Owner passwords are stored in the Terraform state as well, the Key Vault does
  not change that. Keep the state in a backend that encrypts it, or use Entra ID
  owners, which have no password at all.
* Rotating an owner password means tainting its `random_password.owner` entry;
  the new value is written over the existing secret as a new version, and the
  previous versions stay in the vault until the secret is deleted.
* With `key_vault_purge_protection_enabled = false`, which is the default, a
  `terraform destroy` also purges the vault, so its name is free again right
  away. With purge protection on, the vault is only soft deleted and its name
  stays reserved for `key_vault_soft_delete_retention_days`.
