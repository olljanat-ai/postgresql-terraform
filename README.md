# postgresql-terraform

Terraform configuration that creates an Azure Database for PostgreSQL flexible
server with one database on it, reachable two ways:

* as the **owner role**, with a username and a generated password, and
* as a **Microsoft Entra workload identity**, a user assigned managed identity
  that this configuration creates, which connects with an Entra access token
  instead of a password.

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
| `main.tf`                       | Resource group, server, managed identity, database, roles and Key Vault. |
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

As the workload identity, where the access token is the password. This runs on
something that has the identity attached, and asks the instance metadata
endpoint for a token. A user assigned identity has to be named, because a
workload can carry several:

```bash
export PGPASSWORD="$(curl -s -H 'Metadata: true' \
  "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01\
&resource=https://ossrdbms-aad.database.windows.net\
&client_id=$(terraform output -raw workload_identity_client_id)" \
  | jq -r .access_token)"

psql "host=$(terraform output -raw fqdn) \
      user=$(terraform output -raw workload_identity_role) \
      dbname=$(terraform output -raw database_name) sslmode=require"
```

Nothing else about the connection changes: same host, same database, same
rights. The token expires, so a long lived application asks for a fresh one
rather than holding on to the first.

### Attaching the identity to the application

The identity is created here, but attaching it to whatever runs the application
is that workload's own deployment, which is where the knowledge of the workload
is. Both halves are outputs:

```bash
terraform output -raw workload_identity_id         # to attach it to a VM, App Service or AKS
terraform output -raw workload_identity_client_id  # to ask for the token with
```

An AKS workload federates a Kubernetes service account with the identity instead
of attaching it; the same resource id is what the federated credential points
at.

A freshly created identity takes a moment to replicate through Entra ID. The
apply itself does not wait for it, because nothing in it needs to, but a sign in
attempted seconds after the first apply can fail until the replication catches
up.

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

### Why the database is created by the postgresql provider

Steps 3 and 4 both hang off one fact: the owner role owns the database. That is
why the database is created by `postgresql_database` with an explicit `owner`,
and not by `azurerm_postgresql_flexible_server_database`. A database created
over the Azure Resource Manager API is owned by the role the control plane runs
as, not by the owner role, and the two steps then fall apart in order:

* Revoking `CONNECT` from `PUBLIC` takes away the only entry the owner role had
  in the database ACL, because it never got an entry of its own. Signing in then
  fails with `permission denied for database "..." DETAIL: User does not have
  CONNECT privilege.`
* Granting `CONNECT` back by hand gets past the sign in and straight into the
  next wall: `pg_database_owner` is somebody else, so the owner role has no
  `CREATE` on the `public` schema and the first `CREATE TABLE` fails with
  `permission denied for schema public`.

What the database is owned by is worth checking before anything else when a
login is refused:

```sql
SELECT datname, pg_get_userbyid(datdba) AS owner, datacl FROM pg_database;
```

The owner column has to name the owner role. Where the database already exists
and is owned by somebody else, `ALTER DATABASE <name> OWNER TO <owner role>`
moves it, and rerunning the apply is then enough.

`postgresql_grant_role.owner_to_administrator` is what makes any of this legal.
The Azure administrator login is not a superuser, and PostgreSQL only lets a
role create a database owned by another role, hand an existing one over to it,
or `ALTER ROLE ... SET ROLE` into it, while it is a member of that role. Drop
the grant and the ownership the whole design rests on cannot be established at
all.

### Why the workload identity needs no grants either

A database has exactly one owner: `pg_database.datdba` holds a single role. The
workload identity reaches the database by being a **member of the owner role**
rather than by owning it too:

```sql
CREATE ROLE "id-billing-app" LOGIN;
SECURITY LABEL FOR "pgaadauth" ON ROLE "id-billing-app"
  IS 'aadauth,oid=<principal id of the managed identity>,type=service';
GRANT billing_app TO "id-billing-app";
ALTER ROLE "id-billing-app" SET ROLE billing_app;
```

The role is named after the identity, because that is the name Entra ID resolves
at sign in, and the oid in the label is the identity's `principal_id`. Both are
read straight off the `azurerm_user_assigned_identity` resource, so there is no
object id to copy between configurations and no way for the two to drift
apart.

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

### Migrating a database created over the Azure API

A database that already exists as `azurerm_postgresql_flexible_server_database`
moves in here without being recreated: the resource leaves the state, the
database is imported as `postgresql_database.this`, and Terraform hands it over
to the owner role itself. Nothing inside the database is touched. Two steps of
that can destroy it instead, so both are settled before anything is applied.

**Do not simply delete the resource block.** That plans a destroy, and the
database goes with it. Take it out of the state, which leaves the database
standing:

```bash
terraform state rm azurerm_postgresql_flexible_server_database.this
```

From Terraform 1.7 onwards a `removed` block does the same as part of the plan,
which is the reviewable version of it:

```hcl
removed {
  from = azurerm_postgresql_flexible_server_database.this

  lifecycle {
    destroy = false
  }
}
```

**Encoding and collation force a replacement when they differ.** `encoding`,
`lc_collate` and `lc_ctype` are read back from `pg_database` on import and all
three are `ForceNew`, so a `database_collation` that does not match what the
database actually has plans a drop and a create rather than an update. Read the
real values off the server first and set `database_charset` and
`database_collation` to them:

```sql
SELECT pg_encoding_to_char(encoding) AS encoding, datcollate, datctype
FROM pg_database WHERE datname = 'billing';
```

`template` is `ForceNew` as well but is not a risk: the provider fills it in from
the configuration on read, because a database does not record what it was cloned
from, so it never differs.

Then import, as a block rather than the CLI, so that the plan shows the outcome
before the state is written:

```hcl
import {
  to = postgresql_database.this
  id = "billing"
}
```

`terraform plan` has to come back with an in-place update of
`postgresql_database.this` and no replacement anywhere. That update is the
ownership change, `ALTER DATABASE billing OWNER TO billing_app`, which the
provider runs itself and which needs the administrator to be a member of the
owner role — `postgresql_grant_role.owner_to_administrator` again. The `public`
schema follows on its own from there, because `pg_database_owner` resolves to
whoever owns the connected database. Drop the `import` block once the apply has
gone through.

`alter_object_ownership` on `postgresql_database` looks like it would carry the
existing objects across at the same time, and is better left off here: it
reassigns as the *previous* owner and grants that role to the administrator to
do so, which fails when the previous owner is an Azure-internal role. Hand the
objects over as below instead.

One more thing worth checking before the apply rather than after:
`revoke_public_connect` locks out every role that is not the owner, a member of
it, or an administrator. Where something else still reaches this database under
a role of its own, set it to `false` for the migration and turn it back on once
those roles are members of the owner role.

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

## Troubleshooting

### `permission denied for schema public`

The sign in works, and the first statement comes back with:

```
ERROR:  permission denied for schema public
LINE 1: CREATE TABLE IF NOT EXISTS test ()
```

Connecting proves that the role exists, that its password or token is accepted
and that it holds `CONNECT` on the database. It proves nothing about ownership,
and ownership is where every right *inside* the database comes from here. From
PostgreSQL 15 onwards the `public` schema grants `CREATE` to `pg_database_owner`
alone, and that resolves to whoever owns the database the session is connected
to. The error therefore says one thing: the role that signed in is neither the
owner of this database nor a member of that owner.

Four values tell which of the four causes it is. Read them over the failing
connection itself, as the role that fails and in the database it fails in, with
the owner role name in place of `billing_app`:

```sql
SELECT current_database(), current_user;

SELECT pg_get_userbyid(datdba) AS database_owner
FROM pg_database WHERE datname = current_database();

SELECT pg_get_userbyid(nspowner) AS schema_owner, nspacl
FROM pg_namespace WHERE nspname = 'public';

SELECT pg_has_role(current_user, 'billing_app', 'MEMBER') AS is_member,
       pg_has_role(current_user, 'billing_app', 'USAGE')  AS inherits;
```

**1. The wrong database.** `current_database()` is `postgres` rather than the
database this configuration created. A connection string that carries no
`dbname` lands there, or in a database named after the user, and the owner role
has no rights in either: it owns one database and only that one. Nothing is
broken, name the database in the connection.

**2. The database is owned by somebody else.** `database_owner` is not the owner
role. This is where a database created over the Azure Resource Manager API ends
up, whether by `azurerm_postgresql_flexible_server_database` or by
`az postgres flexible-server db create`, and it is the usual answer when the
roles and the grants have been carried into an existing deployment but the
database itself was created elsewhere. See [Why the database is created by the
postgresql provider](#why-the-database-is-created-by-the-postgresql-provider).
Hand it over, as the Azure administrator, which may do so because
`postgresql_grant_role.owner_to_administrator` made it a member of the owner
role:

```sql
ALTER DATABASE billing OWNER TO billing_app;
```

Nothing inside the database is touched and no object changes hands. Reconnect
and `public` follows on its own, because `pg_database_owner` is resolved per
connection. Where the database is to be managed here from now on, import it as
described in [Migrating a database created over the Azure
API](#migrating-a-database-created-over-the-azure-api) rather than leaving the
ownership change outside Terraform.

**3. The `public` schema is owned by a role instead of `pg_database_owner`.**
`schema_owner` should read `pg_database_owner` and `nspacl` should carry
`pg_database_owner=UC/pg_database_owner`. A database restored from a dump taken
on PostgreSQL 14 or older, or one whose schema was dropped and recreated by
hand, has an ordinary role there instead, and moving the database then changes
nothing at all. Run this in that database, as the administrator and after the
database owner is right, so that the membership needed to hand the schema over
exists:

```sql
ALTER SCHEMA public OWNER TO pg_database_owner;
```

**4. The role is not a member of the owner role.** `is_member` is false. A login
created outside this configuration is an ordinary role with no rights in the
database, whatever its password reaches. Make it a member, and have it create
objects as the owner rather than as itself:

```sql
GRANT billing_app TO "app_login";
ALTER ROLE "app_login" SET ROLE billing_app;
```

`ALTER ROLE ... SET ROLE` takes effect at the next sign in. Where `is_member` is
true but `inherits` is false the membership is there and unused: the role is
`NOINHERIT`, so it holds the privileges of the owner only while it has run
`SET ROLE billing_app` by hand. `rolinherit` in `pg_roles` shows which of the
two it is, and `ALTER ROLE "app_login" INHERIT` is the fix.

`GRANT CREATE ON SCHEMA public TO billing_app` gets the failing statement
through and is worth avoiding: it leaves the database owned by somebody else, so
the next thing that rests on ownership fails in turn, whether that is revoking
`CONNECT` from `PUBLIC`, adding the workload identity as a member of the owner,
or dropping the owner role once the application has moved. The ownership is the
fix.

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
role as an Entra principal, and Terraform signs in as it to do exactly that. It
is not the same thing as the workload identity: the administrator is the
identity Terraform itself runs as, while the workload identity is created here
for the application and never administers anything.

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
| `workload_identity_name`                  | Name of the user assigned managed identity created here, and of its PostgreSQL role.   | `string` | `"id-<db>"`        |    no    |
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
| `workload_identity_id`          | Resource id of the managed identity, to attach it to a workload.   |
| `workload_identity_client_id`   | Client id of the managed identity, to ask for a token with.        |
| `workload_identity_principal_id` | Object id of the identity, which is the oid in the security label. |
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
* The managed identity and its PostgreSQL role are both managed here, so
  changing `workload_identity_name` replaces the identity, which gives it a new
  object id, and replaces the role and its label with it. Anything that had the
  old identity attached has to be pointed at the new one.
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
