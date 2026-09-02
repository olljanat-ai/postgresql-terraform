################################################################################
# The database, its owner and the roles that reach it
#
# These are objects inside PostgreSQL rather than Azure resources, so no Azure
# Verified Module covers them and they are managed over the wire protocol.
################################################################################

resource "random_password" "owner" {
  count = var.owner_login ? 1 : 0

  length           = 32
  special          = true
  override_special = "!#%&*()-_=+[]<>:?"
}

# The role that owns the database. With owner_login off it has no password and
# does not sign in: it then only holds the ownership, while the workload
# identity below signs in on its behalf.
resource "postgresql_role" "owner" {
  name     = local.owner_role_name
  login    = var.owner_login
  password = one(random_password.owner[*].result)

  # The module owns both the server and its firewall rule, so waiting for it
  # covers the network path this provider needs.
  depends_on = [module.postgresql_server]
}

# The administrator is not a superuser on Azure, so it can only create a
# database owned by another role, and later revoke privileges on it, while it is
# a member of that role. The membership is granted before the database is
# created, which also makes the provider skip the temporary grant it would
# otherwise revoke right after the database is created.
resource "postgresql_grant_role" "owner_to_administrator" {
  role       = var.administrator_login
  grant_role = postgresql_role.owner.name

  # The administrator created the role, so it is already its grantor and cannot
  # be granted the admin option back.
  with_admin_option = false
}

################################################################################
# The workload identity, which reaches the database as a second owner
################################################################################

# A PostgreSQL database has exactly one owner, so a second identity reaches it
# by being a member of the owner role rather than by owning it too. A member
# passes every ownership check, because PostgreSQL tests ownership with
# has_privs_of_role(current_user, owner) rather than current_user = owner, and
# that includes the pg_database_owner membership carrying the public schema.
#
# The role has no password. What makes Entra ID able to sign in to it is the
# security label below, not the way the role is created.
resource "postgresql_role" "workload_identity" {
  name  = module.workload_identity.resource_name
  login = true

  # ALTER ROLE ... SET ROLE: the identity switches to the owner role at login,
  # so everything it creates is owned by the owner role rather than by itself.
  # Without it the two would end up owning each other's tables, and retiring
  # either one would mean reassigning them first.
  #
  # PostgreSQL checks that the role running this statement, the administrator,
  # may become the owner role, hence the dependency on its membership.
  assume_role = postgresql_role.owner.name

  depends_on = [postgresql_grant_role.owner_to_administrator]
}

resource "postgresql_grant_role" "workload_identity_to_owner" {
  role       = postgresql_role.workload_identity.name
  grant_role = postgresql_role.owner.name

  # The identity is an ordinary user of the database, it does not hand the role
  # on to anybody else.
  with_admin_option = false
}

# This is the whole of what pgaadauth_create_principal_with_oid does: it writes
# the mapping from the role to an Entra object as a security label of the
# pgaadauth provider, which the server then reads while validating an access
# token presented as the password.
#
# Azure only lets a Microsoft Entra administrator write the label, hence the
# second provider, and the administrator of the server has to exist before that
# connection can be made at all. The module creates that administrator, so the
# dependency is on the module rather than on a resource.
resource "postgresql_security_label" "workload_identity" {
  provider = postgresql.entra

  object_type    = "role"
  object_name    = postgresql_role.workload_identity.name
  label_provider = "pgaadauth"
  label          = "aadauth,oid=${module.workload_identity.principal_id},type=service"

  depends_on = [module.postgresql_server]
}

################################################################################
# The database
################################################################################

# The database is created here rather than through the databases input of the
# AVM PostgreSQL module, because the owner is the whole point: that input goes
# through azurerm_postgresql_flexible_server_database, and a database created
# over the Azure Resource Manager API belongs to the role the control plane runs
# as, which leaves the owner role with no entry of its own in the database ACL
# and no pg_database_owner membership. Revoking CONNECT from PUBLIC below then
# locks the owner out of its own database, and granting CONNECT back only moves
# the failure on to the public schema. The ARM API has no owner field at all, so
# no module can close this gap.
resource "postgresql_database" "this" {
  name       = var.database_name
  owner      = postgresql_role.owner.name
  template   = "template0"
  encoding   = var.database_charset
  lc_collate = var.database_collation
  lc_ctype   = var.database_collation

  depends_on = [postgresql_grant_role.owner_to_administrator]
}

# The public schema of a database Azure created is owned by azure_pg_admin and
# grants nothing to pg_database_owner, so owning the database reaches into it
# nowhere: the owner role is left with the USAGE that PUBLIC carries, and the
# first CREATE TABLE fails with "permission denied for schema public" while
# every ownership above it is right. Handing the schema over is the whole repair.
# A database created here needs none of it: its public schema comes from
# template0 owned by pg_database_owner, which already resolves to the owner role.
# The statement runs there too, once, and moves the schema from the one to the
# other without changing who may do what.
#
# The owner role rather than pg_database_owner, which is what template0 carries:
# to hand an object to a role, the provider first makes the administrator a
# member of it, and PostgreSQL refuses that for pg_database_owner, whose one
# member is implicit and situation dependent. The two are the same thing in this
# database anyway, because the owner role is what pg_database_owner resolves to
# here.
resource "postgresql_schema" "public" {
  name     = "public"
  database = postgresql_database.this.name
  owner    = postgresql_role.owner.name

  # The schema exists in every database, so this never creates one: the provider
  # finds it and runs ALTER SCHEMA public OWNER TO instead.
  #
  # It does drop it on the way out, and DROP SCHEMA public RESTRICT fails
  # against a database that holds anything, which would leave terraform destroy
  # stuck on a schema that is about to go with the database. The cascade is what
  # the database drop would do a moment later. Destroying this resource on its
  # own, with -target or by taking the block out, therefore drops every table in
  # the database with it.
  drop_cascade = true

  depends_on = [postgresql_grant_role.owner_to_administrator]
}

# Without this every role on the server can connect to the database through the
# PUBLIC role.
resource "postgresql_grant" "revoke_public_connect" {
  count = var.revoke_public_connect ? 1 : 0

  database    = postgresql_database.this.name
  role        = "public"
  object_type = "database"
  privileges  = []

  depends_on = [postgresql_grant_role.owner_to_administrator]
}
