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
4. **Everything inside the database.** From PostgreSQL 15 onwards `PUBLIC` has
   no `CREATE` on the `public` schema, so who owns that schema decides who may
   create anything at all. `postgresql_schema.public` gives it to the owner
   role, which is where the ownership of the database and the ownership of the
   objects in it meet. So the owner has full rights in its own database, and
   only in that one. `postgresql_version` is validated to be 15 or newer for
   this reason.
5. **Objects that were already there.** Every table carries an owner of its own,
   and one created before this configuration took the database over keeps it, so
   the four steps above can all be right while reading such a table still fails.
   [Objects that already exist](#objects-that-already-exist) hands them over,
   once, and nothing created afterwards needs it.

### Why the `public` schema is handed to the owner role

A database created here has nothing wrong with its `public` schema: `template0`
carries it owned by `pg_database_owner`, the implicit role that resolves to
whoever owns the connected database, and that is the owner role already. Moving
it to the owner role by name changes nothing about who may do what there.

A database Azure created carries it owned by `azure_pg_admin` instead, with
`pg_database_owner` nowhere in the ACL:

```
   schema_owner  |                      nspacl
-----------------+---------------------------------------------------
 azure_pg_admin  | {azure_pg_admin=UC/azure_pg_admin,=U/azure_pg_admin}
```

Owning the database then reaches into the schema nowhere. The owner role is
left with the `USAGE` that `PUBLIC` carries, which is enough to read the schema
and not to create in it, and the first `CREATE TABLE` fails with `permission
denied for schema public` while every ownership above it is right. Anything
adopted from Azure arrives in that state, whether it was created over the Azure
Resource Manager API or came with the server.

`postgresql_schema.public` settles both cases with the same statement, which the
provider runs on an existing schema rather than creating one:

```sql
ALTER SCHEMA public OWNER TO billing_app;
```

The owner role rather than `pg_database_owner`, which would keep the schema
following the database the way `template0` leaves it, because the provider hands
an object over by first making the administrator a member of the role receiving
it, and PostgreSQL refuses that: `pg_database_owner` has one member, implicit
and situation dependent, and no explicit ones. In this database the two amount
to the same role.

The resource drops the schema when it is destroyed, and with `drop_cascade` off
a `DROP SCHEMA public RESTRICT` would fail against a database holding anything,
leaving `terraform destroy` stuck on a schema the database drop was about to
take with it a moment later. It is on, so a destroy of this resource *alone*,
with `-target` or by taking the block out, drops every table in the database
with it.

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
schema does not follow on its own: a database Azure created has it owned by
`azure_pg_admin` rather than by `pg_database_owner`, which is why
`postgresql_schema.public` exists and hands it over in the same apply. Drop the
`import` block once the apply has gone through.

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

`postgresql_schema.public` hands over the *schema*, and `ALTER ROLE ... SET ROLE`
decides who owns whatever is created **from now on**. Neither touches a table
that is already there: a table keeps the owner it was created with and the ACL
that came with it. A database adopted from somewhere else therefore comes out of
the apply able to create and drop tables of its own, and unable to read the ones
it arrived with:

```
ERROR:  permission denied for table orders
```

That is one layer below the schema, and no amount of schema ownership reaches
it. `ALTER SCHEMA public OWNER TO billing_app` rewrites `pg_namespace`, which
decides who may create objects in the schema and nothing else. Every table
carries its own owner in `pg_class.relowner` and its own grants in
`pg_class.relacl`, and on a table that predates the adoption the owner role
appears in neither.

It splits by who created an object rather than by when. Anything the owner role
or the workload identity creates is owned by `billing_app`, because the identity
`SET ROLE`s into it at sign in, so new objects are right by construction and
need nothing here — including new objects created long after the migration.
Anything created by a third login that is not a member of the owner role lands
in the same trap as the old tables, whether that happens today or next year.

Read which objects are on which side, in the database itself:

```sql
SELECT c.relname,
       CASE c.relkind WHEN 'r' THEN 'table' WHEN 'p' THEN 'partitioned table'
                      WHEN 'v' THEN 'view'  WHEN 'm' THEN 'materialized view'
                      WHEN 'S' THEN 'sequence' END AS kind,
       pg_get_userbyid(c.relowner) AS owner
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p', 'v', 'm', 'S')
ORDER BY owner, kind, c.relname;
```

Every row already reading `billing_app` is fine. The rest is a one-off hand
over, run in that database as the administrator, and there are two versions of
it depending on what the old owner is.

**An ordinary role** — the previous application login, a migration user, the
administrator itself — hands over everything it owns in one statement, tables,
sequences, views and functions alike:

```sql
REASSIGN OWNED BY app_legacy TO billing_app;
```

It acts on the connected database only, so connect to `billing` rather than to
`postgres` first. The role running it has to be a member of both roles: it is a
member of `billing_app` through `postgresql_grant_role.owner_to_administrator`,
and `GRANT app_legacy TO pgadmin;` gives it the other half. `REASSIGN OWNED`
leaves the old role owning nothing, which is what makes it droppable afterwards.

**`azure_pg_admin`**, which is where a database created over the Azure API and
then filled in by hand leaves them, is the case where `REASSIGN OWNED BY` is the
wrong tool: it would sweep up whatever else in that database belongs to Azure's
own extensions along with the application's tables. Name the objects instead:

```sql
DO $$
DECLARE
  obj record;
BEGIN
  FOR obj IN
    SELECT c.oid::regclass AS ident,
           CASE c.relkind WHEN 'S' THEN 'SEQUENCE'
                          WHEN 'v' THEN 'VIEW'
                          WHEN 'm' THEN 'MATERIALIZED VIEW'
                          ELSE 'TABLE' END AS kind
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relkind IN ('r', 'p', 'v', 'm', 'S')
      AND c.relowner <> 'billing_app'::regrole
  LOOP
    EXECUTE format('ALTER %s %s OWNER TO billing_app', obj.kind, obj.ident);
  END LOOP;
END
$$;
```

Indexes, constraints and TOAST tables follow their table and are left out on
purpose. A sequence behind a `serial` or an identity column follows its table
too, so the loop reaches some of them after they have already moved, which is a
statement that changes nothing rather than an error. Functions, procedures and
types are separate objects that the query above does not list; where the
database has any, the same loop over `pg_proc` and `pg_type` moves them with
`ALTER ROUTINE ... OWNER TO` and `ALTER TYPE ... OWNER TO`.

Objects in a schema other than `public` need the schema handing over as well —
`postgresql_schema.public` covers the one schema it names — and then the same
loop with that schema in place of `public`.

**Terraform does not do this, and the provider offers no way to.** There is no
resource for `REASSIGN OWNED`, and the objects are data that already exists
rather than desired state: what they are owned by now is knowable only by
looking in the database. `alter_object_ownership` on `postgresql_database` is
the nearest thing and does not reach this case either, because it runs only in
the apply that changes the database owner and reassigns as the previous owner.
The hand over is run once, when the database is adopted, and everything created
after it is owned by the owner role already.

Rerun the query above afterwards: every row should read `billing_app`. Then read
a table over the failing connection itself, as the role that failed, because
that is the thing that was actually broken:

```sql
SELECT count(*) FROM orders;
```

`GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO
billing_app` gets the reads and writes going and is worth avoiding for the same
reason as everywhere else here: it covers the tables that exist at the moment it
runs and no other, and it leaves the owner role unable to `ALTER` or `DROP` any
of them, so the reads work and the next schema migration fails instead. The
ownership is the fix.

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
PostgreSQL 15 onwards `PUBLIC` has no `CREATE` on the `public` schema, so the
right comes from the schema's own owner: the owner role, once
`postgresql_schema.public` has handed it over, or `pg_database_owner`, which
resolves to whoever owns the database, on a schema still as `template0` left it.
The error therefore says that the session holds no `CREATE` there, which is
either because the role that signed in is neither that owner nor a member of it,
or because the schema belongs to a role that grants the database owner nothing.

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

**3. The `public` schema is owned by a role that grants the database owner
nothing.** `schema_owner` should read the owner role. On a database Azure
created it reads this instead:

```
   schema_owner  |                      nspacl
-----------------+---------------------------------------------------
 azure_pg_admin  | {azure_pg_admin=UC/azure_pg_admin,=U/azure_pg_admin}
```

`pg_database_owner` appears nowhere in that ACL, so owning the database reaches
nothing: the owner role is left with the `USAGE` that the empty grantee, which
is `PUBLIC`, carries, and that is enough to read the schema and not to create in
it. Fixing the ownership of the database changes nothing on its own here. A
database restored from a dump taken on PostgreSQL 14 or older, or one whose
schema was dropped and recreated by hand, lands in the same place.

**An apply fixes this.** `postgresql_schema.public` hands the schema to the
owner role, so a database adopted into this configuration is repaired by the
first apply and stays that way, and the plan shows it as an update of that
resource. Where the database is not managed here, or the apply cannot be run
yet, the same statement by hand, in that database, as the administrator:

```sql
ALTER SCHEMA public OWNER TO billing_app;
```

The statement asks two things of the role running it, and the administrator has
both: it has to own the schema, which it does through its `azure_pg_admin`
membership, and it has to be able to become the owner role, which
`postgresql_grant_role.owner_to_administrator` is what gives it. Where the
database owner is wrong as well, hand the database over first: the owner role
needs `CREATE` on the database to be given a schema in it, and owning the
database is where it gets that.

`ALTER SCHEMA ... OWNER` rewrites the grants the old owner made along with the
ownership, so one statement is the whole of it:

```
 schema_owner |                 nspacl
--------------+-------------------------------------------
 billing_app  | {billing_app=UC/billing_app,=U/billing_app}
```

Only the connected database is touched: every other database on the server keeps
whatever its own `public` schema had.

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

### `permission denied for table ...`

Creating a table works, and reading one that was already there does not:

```
ERROR:  permission denied for table orders
```

Nothing regressed to get here. This is the next wall behind [`permission denied
for schema public`](#permission-denied-for-schema-public): handing the schema to
the owner role is what lets a session reach a table at all, and the tables that
were in the database before it was adopted still carry the owner and the grants
they were created with.

The schema and the table are two different objects with two different owners.
`ALTER SCHEMA public OWNER TO billing_app` decides who may create things in the
schema; `pg_class.relowner` and `pg_class.relacl` decide who may read and write
one particular table, and on a table older than the adoption the owner role is
in neither:

```sql
SELECT pg_get_userbyid(relowner) AS table_owner, relacl
FROM pg_class WHERE oid = 'public.orders'::regclass;
```

`table_owner` reads the role that created the table — an old application login,
a migration user, or `azure_pg_admin` on a database filled in through the Azure
portal — and `relacl` is either empty, which means the owner and nobody else, or
lists roles that do not include `billing_app`.

Only objects that predate the adoption are affected, and only those. Anything
the owner role or the workload identity creates from here on is owned by
`billing_app`, which is why the same session can create and drop tables of its
own while these ones refuse it. [Objects that already
exist](#objects-that-already-exist) is the one-off hand over that settles them.

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
  ownership moving by hand first, the `public` schema of the database along with
  the database itself.
* An earlier revision of this configuration took a list of databases and created
  a role per entry. Moving state over from it means renaming the instances, for
  example `terraform state mv 'postgresql_role.owner["billing"]' postgresql_role.owner`.
