locals {
  databases = { for db in var.databases : db.name => db }

  # Both kinds of owner are an ordinary PostgreSQL role, and the databases, the
  # grants and the outputs treat them alike. An Entra owned role is named after
  # the identity, because that is the name Entra ID resolves at sign in.
  owner_role_names = {
    for name, db in local.databases :
    name => db.entra_principal != null ? db.entra_principal.name : coalesce(db.owner_username, "${name}_owner")
  }

  # The owner role signs in with a generated password, unless it is an Entra
  # identity, or unless owner_login is off and it only holds the ownership
  # while its members do the signing in.
  password_owners = {
    for name, db in local.databases :
    name => db if db.entra_principal == null && db.owner_login
  }

  entra_owners = {
    for name, db in local.databases :
    name => db if db.entra_principal != null
  }

  # Further login roles that are members of the owner role. Keyed by
  # "<database>/<role>", because a database may have several of them and a role
  # name alone would not say which database it belongs to.
  owner_members = merge(
    {},
    [
      for name, db in local.databases : {
        for member in db.owner_members :
        "${name}/${member.name}" => {
          database        = name
          name            = member.name
          owner           = local.owner_role_names[name]
          entra_principal = member.entra_principal
        }
      }
    ]...
  )

  password_members = {
    for key, member in local.owner_members :
    key => member if member.entra_principal == null
  }

  entra_members = {
    for key, member in local.owner_members :
    key => member if member.entra_principal != null
  }

  entra_auth_enabled = var.entra_administrator != null
  key_vault_enabled  = var.key_vault_name != null

  # A Key Vault secret name may only carry letters, digits and dashes, while a
  # PostgreSQL role name commonly carries underscores. Only the password
  # authenticated roles have a secret at all.
  owner_secret_names = {
    for name, db in local.password_owners :
    name => replace(local.owner_role_names[name], "_", "-")
  }

  member_secret_names = {
    for key, member in local.password_members :
    key => replace(member.name, "_", "-")
  }

  administrator_secret_name = replace(var.administrator_login, "_", "-")
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

  # Password authentication stays on in either case: Terraform creates the
  # databases and the roles as the built-in administrator, which has no Entra
  # identity behind it.
  authentication {
    password_auth_enabled         = true
    active_directory_auth_enabled = local.entra_auth_enabled
    tenant_id                     = local.entra_auth_enabled ? data.azurerm_client_config.current.tenant_id : null
  }

  zone = var.zone

  tags = var.tags

  lifecycle {
    precondition {
      condition     = length(local.entra_owners) + length(local.entra_members) == 0 || var.entra_administrator != null
      error_message = "entra_administrator has to be set when a database has an Entra ID identity as its owner or among its owner_members: only an Entra administrator may mark a role as an Entra principal."
    }
  }
}

resource "azurerm_postgresql_flexible_server_firewall_rule" "this" {
  for_each = var.firewall_rules

  name             = each.key
  server_id        = azurerm_postgresql_flexible_server.this.id
  start_ip_address = each.value.start_ip_address
  end_ip_address   = each.value.end_ip_address
}

resource "azurerm_postgresql_flexible_server_active_directory_administrator" "this" {
  count = local.entra_auth_enabled ? 1 : 0

  server_name         = azurerm_postgresql_flexible_server.this.name
  resource_group_name = azurerm_resource_group.this.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  object_id           = var.entra_administrator.object_id
  principal_name      = var.entra_administrator.principal_name
  principal_type      = var.entra_administrator.principal_type
}

################################################################################
# Databases and their owners
################################################################################

resource "random_password" "owner" {
  for_each = local.password_owners

  length           = 32
  special          = true
  override_special = "!#%&*()-_=+[]<>:?"
}

# One role per database, whichever way it authenticates. An Entra owner has no
# password: what makes Entra ID able to sign in to it is the security label
# below, not the way the role is created. An owner with owner_login = false has
# no password either, and does not sign in at all, it only holds the ownership
# while the members below sign in on its behalf.
resource "postgresql_role" "owner" {
  for_each = local.databases

  name     = local.owner_role_names[each.key]
  login    = each.value.entra_principal != null || each.value.owner_login
  password = each.value.entra_principal == null && each.value.owner_login ? random_password.owner[each.key].result : null

  depends_on = [
    azurerm_postgresql_flexible_server.this,
    azurerm_postgresql_flexible_server_firewall_rule.this,
  ]
}

# Entra owned roles used to be a resource of their own, before an owner could
# also be a role that never signs in and the three cases became one resource.
moved {
  from = postgresql_role.entra_owner
  to   = postgresql_role.owner
}

# This is the whole of what pgaadauth_create_principal_with_oid does: it writes
# the mapping from the role to an Entra object as a security label of the
# pgaadauth provider, which the server then reads while validating an access
# token presented as the password.
#
# Azure only lets a Microsoft Entra administrator write the label, hence the
# second provider, and the administrator of the server has to exist before that
# connection can be made at all.
resource "postgresql_security_label" "entra_owner" {
  provider = postgresql.entra

  for_each = local.entra_owners

  object_type    = "role"
  object_name    = postgresql_role.owner[each.key].name
  label_provider = "pgaadauth"
  label          = "aadauth,oid=${each.value.entra_principal.object_id},type=${each.value.entra_principal.type}"

  depends_on = [azurerm_postgresql_flexible_server_active_directory_administrator.this]
}

# The administrator is not a superuser on Azure, so it can only create a
# database owned by another role, and later revoke privileges on it, while it is
# a member of that role. The membership is granted before the database is
# created, which also makes the provider skip the temporary grant it would
# otherwise revoke right after the database is created.
resource "postgresql_grant_role" "owner_to_administrator" {
  for_each = local.databases

  role       = var.administrator_login
  grant_role = local.owner_role_names[each.key]

  # The administrator created the role, so it is already its grantor and cannot
  # be granted the admin option back.
  with_admin_option = false

  depends_on = [postgresql_role.owner]
}

################################################################################
# Further owners of a database
################################################################################

# A member is a login role of its own that is granted the owner role, so it has
# the rights of the owner without the database changing hands. Several of them
# can exist side by side, each authenticating its own way, which is what lets an
# application move from a password to an Entra workload identity while both
# still work.

resource "random_password" "member" {
  for_each = local.password_members

  length           = 32
  special          = true
  override_special = "!#%&*()-_=+[]<>:?"
}

resource "postgresql_role" "member" {
  for_each = local.owner_members

  name     = each.value.name
  login    = true
  password = each.value.entra_principal == null ? random_password.member[each.key].result : null

  # ALTER ROLE ... SET ROLE: the member switches to the owner role at login, so
  # everything it creates is owned by the owner role rather than by the member
  # itself. Without it the members of one database would end up owning each
  # other's tables, and dropping a member would mean reassigning them first.
  #
  # PostgreSQL checks that the role running this statement, the administrator,
  # may become the owner role, hence the dependency on its membership.
  assume_role = each.value.owner

  depends_on = [
    azurerm_postgresql_flexible_server.this,
    azurerm_postgresql_flexible_server_firewall_rule.this,
    postgresql_grant_role.owner_to_administrator,
  ]
}

resource "postgresql_grant_role" "member_to_owner" {
  for_each = local.owner_members

  role       = postgresql_role.member[each.key].name
  grant_role = each.value.owner

  # A member is an ordinary user of the database, it does not hand the role on.
  with_admin_option = false
}

resource "postgresql_security_label" "member" {
  provider = postgresql.entra

  for_each = local.entra_members

  object_type    = "role"
  object_name    = postgresql_role.member[each.key].name
  label_provider = "pgaadauth"
  label          = "aadauth,oid=${each.value.entra_principal.object_id},type=${each.value.entra_principal.type}"

  depends_on = [azurerm_postgresql_flexible_server_active_directory_administrator.this]
}

################################################################################
# The databases themselves
################################################################################

resource "postgresql_database" "this" {
  for_each = local.databases

  depends_on = [postgresql_grant_role.owner_to_administrator]

  name       = each.key
  owner      = local.owner_role_names[each.key]
  template   = "template0"
  encoding   = each.value.charset
  lc_collate = each.value.collation
  lc_ctype   = each.value.collation
}

################################################################################
# Hardening
################################################################################

# Without this every role, including the owners of the other databases, can
# connect to the database through the PUBLIC role.
resource "postgresql_grant" "revoke_public_connect" {
  for_each = var.revoke_public_connect ? local.databases : {}

  database    = each.key
  role        = "public"
  object_type = "database"
  privileges  = []

  depends_on = [
    postgresql_database.this,
    postgresql_grant_role.owner_to_administrator,
  ]
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

resource "azurerm_key_vault_secret" "owner" {
  for_each = local.key_vault_enabled ? local.password_owners : {}

  name         = local.owner_secret_names[each.key]
  value        = random_password.owner[each.key].result
  key_vault_id = azurerm_key_vault.this[0].id
  content_type = "PostgreSQL password"

  tags = merge(var.tags, {
    server   = azurerm_postgresql_flexible_server.this.name
    database = each.key
    role     = local.owner_role_names[each.key]
  })

  depends_on = [time_sleep.key_vault_role_assignment]
}

resource "azurerm_key_vault_secret" "member" {
  for_each = local.key_vault_enabled ? local.password_members : {}

  name         = local.member_secret_names[each.key]
  value        = random_password.member[each.key].result
  key_vault_id = azurerm_key_vault.this[0].id
  content_type = "PostgreSQL password"

  tags = merge(var.tags, {
    server   = azurerm_postgresql_flexible_server.this.name
    database = each.value.database
    role     = each.value.name
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
