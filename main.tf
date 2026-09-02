locals {
  # The owner is an ordinary PostgreSQL role that happens to own the database.
  owner_role_name = coalesce(var.owner_username, "${var.database_name}_owner")

  # The identity is named after the database it reaches, unless it is given a
  # name of its own. This is also the PostgreSQL role name.
  workload_identity_name = coalesce(var.workload_identity_name, "id-${var.database_name}")

  key_vault_enabled = var.key_vault_name != null

  # A Key Vault secret name may only carry letters, digits and dashes, while a
  # PostgreSQL role name commonly carries underscores.
  owner_secret_name         = replace(local.owner_role_name, "_", "-")
  administrator_secret_name = replace(var.administrator_login, "_", "-")

  firewall_rule_enabled = var.firewall_rule_start_ip_address != null && var.firewall_rule_end_ip_address != null
}

data "azurerm_client_config" "current" {}

resource "azurerm_resource_group" "this" {
  name     = var.resource_group_name
  location = var.location

  tags = var.tags
}

resource "azurerm_postgresql_flexible_server" "this" {
  name                = var.server_name
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  version             = var.postgresql_version
  sku_name            = var.sku_name
  storage_mb          = var.storage_mb
  auto_grow_enabled   = true

  high_availability {
    mode = "ZoneRedundant"
  }

  administrator_login    = var.administrator_login
  administrator_password = var.administrator_password

  backup_retention_days         = var.backup_retention_days
  public_network_access_enabled = var.public_network_access_enabled

  # Password authentication stays on alongside Entra ID: Terraform creates the
  # database and the roles as the built-in administrator, which has no Entra
  # identity behind it.
  authentication {
    password_auth_enabled         = true
    active_directory_auth_enabled = true
    tenant_id                     = data.azurerm_client_config.current.tenant_id
  }

  zone = var.zone

  tags = var.tags

  lifecycle {
    # Checked here rather than on the firewall rule, because with only one of
    # the two set the rule is not created at all and a precondition on it would
    # never run.
    precondition {
      condition     = (var.firewall_rule_start_ip_address == null) == (var.firewall_rule_end_ip_address == null)
      error_message = "firewall_rule_start_ip_address and firewall_rule_end_ip_address have to be set together, or both left unset."
    }
  }
}

resource "azurerm_postgresql_flexible_server_firewall_rule" "this" {
  count = local.firewall_rule_enabled ? 1 : 0

  name             = var.firewall_rule_name
  server_id        = azurerm_postgresql_flexible_server.this.id
  start_ip_address = var.firewall_rule_start_ip_address
  end_ip_address   = var.firewall_rule_end_ip_address
}

resource "azurerm_postgresql_flexible_server_active_directory_administrator" "this" {
  server_name         = azurerm_postgresql_flexible_server.this.name
  resource_group_name = azurerm_resource_group.this.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  object_id           = var.entra_administrator.object_id
  principal_name      = var.entra_administrator.principal_name
  principal_type      = var.entra_administrator.principal_type
}

################################################################################
# The owner of the database
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

  depends_on = [
    azurerm_postgresql_flexible_server.this,
    azurerm_postgresql_flexible_server_firewall_rule.this,
  ]
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

# The user assigned managed identity of the application. It is created here
# rather than passed in, so that the identity, the PostgreSQL role and the label
# tying the two together are one unit: there is no object id to copy between
# configurations and no way for them to drift apart.
#
# Attaching it to whatever runs the application, a virtual machine, an App
# Service or an AKS workload, is that workload's own deployment. The identity
# and its client id are outputs for exactly that.
resource "azurerm_user_assigned_identity" "workload" {
  name                = local.workload_identity_name
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location

  tags = var.tags
}

# A PostgreSQL database has exactly one owner, so a second identity reaches it
# by being a member of the owner role rather than by owning it too. A member
# passes every ownership check, because PostgreSQL tests ownership with
# has_privs_of_role(current_user, owner) rather than current_user = owner, and
# that includes the pg_database_owner membership carrying the public schema.
#
# The role has no password. What makes Entra ID able to sign in to it is the
# security label below, not the way the role is created.
resource "postgresql_role" "workload_identity" {
  name  = azurerm_user_assigned_identity.workload.name
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
# connection can be made at all.
resource "postgresql_security_label" "workload_identity" {
  provider = postgresql.entra

  object_type    = "role"
  object_name    = postgresql_role.workload_identity.name
  label_provider = "pgaadauth"
  label          = "aadauth,oid=${azurerm_user_assigned_identity.workload.principal_id},type=service"

  depends_on = [azurerm_postgresql_flexible_server_active_directory_administrator.this]
}

################################################################################
# The database
################################################################################

# The database is created here rather than with
# azurerm_postgresql_flexible_server_database, because the owner is the whole
# point: a database created over the Azure Resource Manager API belongs to the
# role the control plane runs as, which leaves the owner role with no entry of
# its own in the database ACL and no pg_database_owner membership. Revoking
# CONNECT from PUBLIC below then locks the owner out of its own database, and
# granting CONNECT back only moves the failure on to the public schema.
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

################################################################################
# Key Vault holding the passwords
################################################################################

resource "azurerm_key_vault" "this" {
  count = local.key_vault_enabled ? 1 : 0

  name                = var.key_vault_name
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = var.key_vault_sku_name

  # Access to the secrets is granted with Azure RBAC role assignments instead of
  # the legacy vault access policies.
  rbac_authorization_enabled = true

  soft_delete_retention_days = var.key_vault_soft_delete_retention_days
  purge_protection_enabled   = var.key_vault_purge_protection_enabled

  # Terraform writes the secrets over the data plane, so it needs to reach the
  # vault itself, not only the Azure Resource Manager API.
  public_network_access_enabled = var.key_vault_public_network_access_enabled

  tags = var.tags
}

# Creating a vault grants no access to the secrets inside it, not even to the
# identity that created it, so Terraform has to give itself the data plane role
# that lets it write them.
resource "azurerm_role_assignment" "key_vault_secrets_officer" {
  count = local.key_vault_enabled && var.key_vault_grant_deployer_access ? 1 : 0

  scope                = azurerm_key_vault.this[0].id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
  principal_type       = "User"

  # The role is assigned to the identity Terraform runs as, which exists by
  # definition, so the provider does not have to wait for Entra to replicate it.
  skip_service_principal_aad_check = true
}

# A fresh role assignment takes a while to reach the data plane of the vault,
# and a secret written before it is there fails with "Caller is not authorized
# to perform action on resource". A minute is enough in practice; when it is
# not, the assignment has propagated by the time the apply is repeated.
resource "time_sleep" "key_vault_role_assignment" {
  count = length(azurerm_role_assignment.key_vault_secrets_officer)

  create_duration = "60s"

  triggers = {
    role_assignment_id = azurerm_role_assignment.key_vault_secrets_officer[0].id
  }
}

# The workload identity has no password, so there is one owner secret and no
# more. It disappears together with the password when owner_login is turned off.
resource "azurerm_key_vault_secret" "owner" {
  count = local.key_vault_enabled && var.owner_login ? 1 : 0

  name         = local.owner_secret_name
  value        = random_password.owner[0].result
  key_vault_id = azurerm_key_vault.this[0].id
  content_type = "PostgreSQL password"

  tags = merge(var.tags, {
    server   = azurerm_postgresql_flexible_server.this.name
    database = var.database_name
    role     = local.owner_role_name
  })

  depends_on = [time_sleep.key_vault_role_assignment]
}

# The administrator password is passed in rather than generated here, but the
# vault is where the rest of the credentials of this server live.
resource "azurerm_key_vault_secret" "administrator" {
  count = local.key_vault_enabled && var.key_vault_store_administrator_password ? 1 : 0

  name         = local.administrator_secret_name
  value        = var.administrator_password
  key_vault_id = azurerm_key_vault.this[0].id
  content_type = "PostgreSQL password"

  tags = merge(var.tags, {
    server = azurerm_postgresql_flexible_server.this.name
    role   = var.administrator_login
  })

  depends_on = [time_sleep.key_vault_role_assignment]
}
