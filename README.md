# postgresql-terraform

Terraform configuration that creates an Azure Database for PostgreSQL flexible
server with one database on it, reachable two ways:

* as the **owner role**, with a username and a generated password, and
* as a **Microsoft Entra workload identity**, which connects with an Entra
  access token instead of a password.

Both have exactly the same access to the database, so an application that
signs in with a password today can move to its managed identity whenever the
application team is ready, without the database changing hands and without a
window where only one of the two works. Once nothing uses the password any
more, `owner_login = false` retires it.

The generated owner password is written into an Azure Key Vault, so that the
application has somewhere to read it from that is not the Terraform state.

## Layout

| File                            | Contents                                            |
| ------------------------------- | --------------------------------------------------- |
| `versions.tf`                   | Provider requirements and the two PostgreSQL providers. |
| `variables.tf`                  | Input variables.                                    |
| `main.tf`                       | Resource group, server, database, roles and Key Vault. |
| `outputs.tf`                    | Outputs.                                            |
| `environments/prototype.tfvars` | A worked example.                                   |

## Usage

```bash
export TF_VAR_administrator_password="$(openssl rand -base64 24)"

terraform init
terraform apply -var-file=environments/prototype.tfvars
```

Terraform manages the database and its roles over port 5432, so the address it
runs from has to be allowed in by `firewall_rule_start_ip_address` and
`firewall_rule_end_ip_address`, unless the server is reached over a private
endpoint.

Read the generated owner password afterwards, either from the Key Vault:

```bash
az keyvault secret show \
  --vault-name "$(terraform output -raw key_vault_name)" \
  --name "$(terraform output -raw owner_password_secret)" \
  --query value -o tsv
```

or out of the state:

```bash
terraform output -raw owner_password
```

### Connecting

As the owner, with its password:

```bash
PGPASSWORD="$(az keyvault secret show \
  --vault-name "$(terraform output -raw key_vault_name)" \
  --name "$(terraform output -raw owner_password_secret)" \
  --query value -o tsv)" \
  psql "host=$(terraform output -raw fqdn) \
        user=$(terraform output -raw owner_role) \
        dbname=$(terraform output -raw database_name) sslmode=require"
```

As the workload identity, where the access token is the password:

```bash
export PGPASSWORD="$(az account get-access-token \
  --resource https://ossrdbms-aad.database.windows.net \
  --query accessToken -o tsv)"

psql "host=$(terraform output -raw fqdn) \
      user=$(terraform output -raw workload_identity_role) \
      dbname=$(terraform output -raw database_name) sslmode=require"
```

A workload running in Azure requests the same token from the instance metadata
endpoint instead of the Azure CLI. Nothing else about the connection changes:
same host, same database, same rights.

## How the access works

There are no `GRANT` statements on tables or schemas here, and none are needed.
Access comes from **ownership**, which in PostgreSQL is not a privilege that is
handed out but a property a role has.

1. **Signing in.** Both roles are created `LOGIN`. The owner authenticates with
   its generated password. The workload identity has no password: it carries a
   security label that maps it to an Entra object, and the server validates the
   access token presented in the password field against it.
2. **Reaching the server.** The firewall rule has to let the client in.
3. **`CONNECT` on the database.** `CREATE DATABASE ... OWNER <role>` leaves the
   owner holding `CONNECT`, `CREATE` and `TEMPORARY` in the database ACL, in an
   entry of its own. Revoking everything from `PUBLIC` therefore locks out every
   other role on the server without touching the owner.
4. **Everything inside the database.** From PostgreSQL 15 onwards the `public`
   schema is owned by `pg_database_owner`, an implicit role whose membership is
   whoever owns the connected database, and `PUBLIC` no longer has `CREATE` on
   it. So the owner has full rights in its own database, and only in that one.
   `postgresql_version` is validated to be 15 or newer for this reason.

### Why the workload identity needs no grants either

A database has exactly one owner: `pg_database.datdba` holds a single role. The
workload identity reaches the database by being a **member of the owner role**
rather than by owning it too:

```sql
CREATE ROLE "id-billing-app" LOGIN;
SECURITY LABEL FOR "pgaadauth" ON ROLE "id-billing-app"
  IS 'aadauth,oid=5c9d1f2e-7a44-4b1c-9f83-2d6e0a7b1c45,type=service';
GRANT billing_app TO "id-billing-app";
ALTER ROLE "id-billing-app" SET ROLE billing_app;
```

A member passes every ownership check, because PostgreSQL tests ownership with
`has_privs_of_role(current_user, owner)` rather than `current_user = owner`, and
the `pg_database_owner` membership that carries the `public` schema is reached
through the same expansion.

The `ALTER ROLE ... SET ROLE` in the last line is what makes the arrangement
survive a migration. Without it, tables the workload identity creates would be
owned by `id-billing-app` and the owner role could not alter or drop them, so
the two logins would drift apart and there would be no way back. With it, both
create objects owned by `billing_app`, and the two are genuinely
interchangeable in either direction.

The database itself never changes hands, so adding the identity is a purely
additive apply: nothing is reassigned and the application using the password is
untouched.

### Moving the application to the workload identity

1. Apply this configuration. Both logins work.
2. The application team switches its connection to the identity: user
   `id-billing-app`, and an access token from the instance metadata endpoint as
   the password. No password is involved and nothing is read from the Key Vault.
3. Once nothing signs in as `billing_app` any more, set `owner_login = false`
   and apply. The owner role keeps owning the database and everything in it, but
   it can no longer sign in, and its generated password and Key Vault secret are
   gone.

Step 3 is reversible: setting `owner_login` back to true generates a new
password and writes it to the vault again. The old secret is soft deleted rather
than removed though, so on a vault with `key_vault_purge_protection_enabled` the
name stays reserved until the retention period runs out, and the write fails
until it is recovered or purged.

### Objects that already exist

`ALTER ROLE ... SET ROLE` only affects what is created from now on. If the
database is reaching this configuration from somewhere else and its objects are
owned by some other role, hand them over once, as that role or as the
administrator:

```sql
REASSIGN OWNED BY <old role> TO billing_app;
```

Terraform does not do this: it is a one-off migration of data that already
exists, not part of the desired state.

## Where the passwords are kept

Setting `key_vault_name` creates an Azure Key Vault into the same resource group
and writes the generated owner password into it, in a secret named after the
owner role with the underscores turned into dashes, because a Key Vault secret
name may only carry letters, digits and dashes.

| Role          | Secret        |
| ------------- | ------------- |
| `billing_app` | `billing-app` |

The administrator password is written there too unless
`key_vault_store_administrator_password` is turned off. The workload identity
has no password at all, so it has no secret.

The vault uses Azure RBAC rather than the legacy access policies, and creating a
vault grants no access to the secrets inside it. Terraform therefore assigns
itself **Key Vault Secrets Officer** on the vault, which needs the identity it
runs as to be allowed to create role assignments, so Owner or User Access
Administrator on the resource group or the subscription. When that access is
granted outside of this configuration instead, set
`key_vault_grant_deployer_access = false`. A fresh role assignment takes a while
to reach the data plane, which is what the one minute wait in `main.tf` is for.

Grant the application reading the password the **Key Vault Secrets User** role
on the vault or on the secret. That is deliberately not done here, because it is
the application's deployment that knows its identity.

Leaving `key_vault_name` unset skips the vault, and the password then lives in
the state and in the `owner_password` output only.

## Microsoft Entra ID

`entra_administrator` makes an Entra principal a Microsoft Entra administrator
of the server. It is required, because only an Entra administrator may mark a
role as an Entra principal, and Terraform signs in as it to do exactly that.

### How the principal is created

An Entra principal inside PostgreSQL is an ordinary role carrying a security
label of the `pgaadauth` label provider, which maps it to an Entra object. That
is all `pgaadauth_create_principal_with_oid()` does, and both statements are
plain resources here: `postgresql_role` and `postgresql_security_label`. Azure
documents the label as [the way to enable Entra authentication for an existing
role][ms-label], and the provider has carried
[`postgresql_security_label`][tf-label] since 1.25, with the `pgaadauth` case as
its example. An earlier revision of this configuration instead called
`pgaadauth_create_principal_with_oid()` over `psql` from a `local-exec`
provisioner, which needed `psql` and the Azure CLI on the machine Terraform ran
from and could neither read back nor destroy what it had created.

Only an Entra administrator may write the label, so that one statement goes over
a second `postgresql` provider that authenticates with an Entra access token
(`azure_identity_auth`, [documented in the provider][tf-azure]). The provider
acquires the token itself, from the same credential chain the `azurerm` provider
uses. Everything else — the roles, the database, the grants — is created by the
built-in administrator over the primary connection.

[ms-label]: https://learn.microsoft.com/en-us/azure/postgresql/security/security-manage-entra-users
[tf-label]: https://registry.terraform.io/providers/cyrilgdn/postgresql/latest/docs/resources/postgresql_security_label
[tf-azure]: https://registry.terraform.io/providers/cyrilgdn/postgresql/latest/docs#azure

## Variables

| Name                                      | Description                                                                            | Type     | Default            | Required |
| ----------------------------------------- | -------------------------------------------------------------------------------------- | -------- | ------------------ | :------: |
| `subscription_id`                         | Azure subscription the resources are created into.                                     | `string` | n/a                |   yes    |
| `resource_group_name`                     | Resource group, created by this configuration.                                         | `string` | n/a                |   yes    |
| `location`                                | Azure region.                                                                          | `string` | `"swedencentral"`  |    no    |
| `server_name`                             | Name of the flexible server, globally unique.                                          | `string` | n/a                |   yes    |
| `postgresql_version`                      | Major PostgreSQL version, 15 or newer.                                                 | `string` | `"15"`             |    no    |
| `sku_name`                                | SKU of the server.                                                                     | `string` | `"B_Standard_B2s"` |    no    |
| `zone`                                    | Availability zone the server is pinned to.                                             | `string` | `"1"`              |    no    |
| `storage_mb`                              | Storage in megabytes.                                                                  | `number` | `32768`            |    no    |
| `backup_retention_days`                   | Days backups are kept.                                                                 | `number` | `7`                |    no    |
| `administrator_login`                     | Login of the built-in administrator.                                                   | `string` | `"pgadmin"`        |    no    |
| `administrator_password`                  | Password of the built-in administrator. Pass as `TF_VAR_administrator_password`.       | `string` | n/a                |   yes    |
| `public_network_access_enabled`           | Whether the server is reachable from the internet.                                     | `bool`   | `true`             |    no    |
| `firewall_rule_name`                      | Name of the firewall rule.                                                             | `string` | `"terraform"`      |    no    |
| `firewall_rule_start_ip_address`          | First allowed address. Unset creates no rule.                                          | `string` | `null`             |    no    |
| `firewall_rule_end_ip_address`            | Last allowed address.                                                                  | `string` | `null`             |    no    |
| `entra_administrator`                     | Entra principal that becomes a Microsoft Entra administrator of the server.            | `object` | n/a                |   yes    |
| `database_name`                           | Name of the database.                                                                  | `string` | n/a                |   yes    |
| `database_charset`                        | Encoding of the database.                                                              | `string` | `"UTF8"`           |    no    |
| `database_collation`                      | Collation of the database.                                                             | `string` | `"en_US.utf8"`     |    no    |
| `owner_username`                          | Name of the owner role.                                                                | `string` | `"<db>_owner"`     |    no    |
| `owner_login`                             | Whether the owner role itself signs in.                                                | `bool`   | `true`             |    no    |
| `workload_identity`                       | Entra workload identity that gets the same access as the owner.                        | `object` | n/a                |   yes    |
| `revoke_public_connect`                   | Revoke `CONNECT` from `PUBLIC` on the database.                                        | `bool`   | `true`             |    no    |
| `tags`                                    | Tags applied to the resource group and the server.                                     | `map`    | `{}`               |    no    |
| `key_vault_name`                          | Key Vault the owner password is written to. Unset skips the vault.                     | `string` | `null`             |    no    |
| `key_vault_sku_name`                      | SKU of the vault.                                                                      | `string` | `"standard"`       |    no    |
| `key_vault_soft_delete_retention_days`    | Days a deleted vault can be recovered, 7 to 90.                                        | `number` | `7`                |    no    |
| `key_vault_purge_protection_enabled`      | Keep a deleted vault for the whole retention period. Cannot be undone.                 | `bool`   | `false`            |    no    |
| `key_vault_public_network_access_enabled` | Whether the vault is reachable from the internet.                                      | `bool`   | `true`             |    no    |
| `key_vault_grant_deployer_access`         | Assign Key Vault Secrets Officer on the vault to the identity Terraform runs as.       | `bool`   | `true`             |    no    |
| `key_vault_store_administrator_password`  | Also store the administrator password in the vault.                                    | `bool`   | `true`             |    no    |

### `entra_administrator`

| Field            | Description                                                                     | Default  |
| ---------------- | --------------------------------------------------------------------------------- | -------- |
| `object_id`      | Entra object id of the principal.                                               | n/a      |
| `principal_name` | User principal name of a user, or display name of a group or service principal. | n/a      |
| `principal_type` | `User`, `Group` or `ServicePrincipal`.                                          | `"User"` |

### `workload_identity`

| Field       | Description                                                                                        | Default |
| ----------- | ---------------------------------------------------------------------------------------------------- | ------- |
| `name`      | Name of the PostgreSQL role, which is the display name of the identity, not its application id.    | n/a     |
| `object_id` | Object id of the service principal of the identity, from `az identity show --query principalId`.   | n/a     |

## Outputs

| Name                            | Description                                                        |
| ------------------------------- | ------------------------------------------------------------------ |
| `resource_group_name`           | Name of the resource group.                                        |
| `server_id`                     | Resource id of the server.                                         |
| `server_name`                   | Name of the server.                                                |
| `fqdn`                          | Host name of the server.                                           |
| `administrator_login`           | Login of the built-in administrator.                               |
| `database_name`                 | Name of the created database.                                      |
| `owner_role`                    | Role that owns the database.                                       |
| `owner_login_enabled`           | Whether the owner role can still sign in.                          |
| `workload_identity_role`        | Role the workload identity signs in as.                            |
| `owner_password`                | Generated owner password, `null` when `owner_login` is off (sensitive). |
| `key_vault_id`                  | Resource id of the Key Vault, `null` when no vault is created.     |
| `key_vault_name`                | Name of the Key Vault, `null` when no vault is created.            |
| `key_vault_uri`                 | Data plane URI of the Key Vault, `null` when no vault is created.  |
| `owner_password_secret`         | Name of the secret holding the owner password.                     |
| `administrator_password_secret` | Name of the secret holding the administrator password.             |

## Notes

* Azure offers a different set of PostgreSQL versions per SKU and region. When
  the requested combination is not offered, the create fails with
  `ParameterOutOfRange: The value of the 'Version' should be in: []`, an empty
  list rather than the versions that would work. List them with
  `az postgres flexible-server list-skus --location <region> --output table`.
* The workload identity is a managed role here, so renaming it in
  `workload_identity.name` drops the role and creates a new one.
* The owner password is stored in the Terraform state as well, the Key Vault
  does not replace a remote backend with restricted access.
* Rotating the owner password means tainting `random_password.owner`:
  `terraform apply -replace=random_password.owner[0]`.
* Changing `owner_username` renames the owner role, which Terraform does with a
  drop and a create. Renaming it after the database exists therefore needs the
  ownership moving by hand first.
* An earlier revision of this configuration took a list of databases and created
  a role per entry. Moving state over from it means renaming the instances, for
  example `terraform state mv 'postgresql_role.owner["billing"]' postgresql_role.owner`.
