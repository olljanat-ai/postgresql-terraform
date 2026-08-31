locals {
  databases          = { for db in var.databases : db.name => db }
  password_databases = { for name, db in local.databases : name => db if db.entra_principal == null }
  entra_databases    = { for name, db in local.databases : name => db if db.entra_principal != null }

  entra_auth_enabled = var.entra_administrator != null

  administrator_password = coalesce(var.administrator_password, one(random_password.administrator[*].result))
}

resource "random_password" "administrator" {
  count = var.administrator_password == null ? 1 : 0

  length           = 32
  special          = true
  override_special = "!#%&*()-_=+[]<>:?"
}

resource "azurerm_postgresql_flexible_server" "this" {
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location
  version             = var.postgresql_version
  sku_name            = var.sku_name
  storage_mb          = var.storage_mb

  administrator_login    = var.administrator_login
  administrator_password = local.administrator_password

  backup_retention_days         = var.backup_retention_days
  public_network_access_enabled = var.public_network_access_enabled

  authentication {
    password_auth_enabled         = true
    active_directory_auth_enabled = local.entra_auth_enabled
    tenant_id                     = local.entra_auth_enabled ? var.entra_administrator.tenant_id : null
  }

  tags = var.tags

  lifecycle {
    precondition {
      condition     = length(local.entra_databases) == 0 || var.entra_administrator != null
      error_message = "entra_administrator has to be set when a database is owned by an Entra ID identity: only an Entra administrator can create Entra principals inside PostgreSQL."
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
  resource_group_name = var.resource_group_name
  tenant_id           = var.entra_administrator.tenant_id
  object_id           = var.entra_administrator.object_id
  principal_name      = var.entra_administrator.principal_name
  principal_type      = var.entra_administrator.principal_type
}

################################################################################
# Databases owned by a username + password role
################################################################################

resource "random_password" "owner" {
  for_each = local.password_databases

  length           = 32
  special          = true
  override_special = "!#%&*()-_=+[]<>:?"
}

resource "postgresql_role" "owner" {
  for_each = local.password_databases

  name     = coalesce(each.value.owner_username, "${each.key}_owner")
  login    = true
  password = random_password.owner[each.key].result

  depends_on = [azurerm_postgresql_flexible_server_firewall_rule.this]
}

resource "postgresql_database" "password" {
  for_each = local.password_databases

  name       = each.key
  owner      = postgresql_role.owner[each.key].name
  template   = "template0"
  encoding   = each.value.charset
  lc_collate = each.value.collation
  lc_ctype   = each.value.collation
}

################################################################################
# Databases owned by a Microsoft Entra ID identity
################################################################################

# Entra principals are not plain PostgreSQL roles: they carry a pgaadauth
# security label that Azure uses to map the Entra token to the role. There is no
# Terraform resource for them, so they are created with the pgaadauth helper
# function, connecting as the Entra administrator of the server. The role is
# then granted to the built-in administrator, so that Terraform can hand the
# ownership of the database over to it.
resource "terraform_data" "entra_principal" {
  for_each = local.entra_databases

  triggers_replace = {
    server         = azurerm_postgresql_flexible_server.this.id
    administrator  = var.administrator_login
    principal_name = each.value.entra_principal.name
    principal_oid  = each.value.entra_principal.object_id
    principal_type = each.value.entra_principal.type
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]

    environment = {
      PGHOST         = azurerm_postgresql_flexible_server.this.fqdn
      PGUSER         = var.entra_administrator.principal_name
      PGDATABASE     = "postgres"
      PGSSLMODE      = "require"
      ADMINISTRATOR  = var.administrator_login
      PRINCIPAL_NAME = each.value.entra_principal.name
      PRINCIPAL_OID  = each.value.entra_principal.object_id
      PRINCIPAL_TYPE = each.value.entra_principal.type
    }

    command = <<-EOT
      set -euo pipefail

      PGPASSWORD="$(az account get-access-token \
        --resource https://ossrdbms-aad.database.windows.net \
        --query accessToken --output tsv)"
      export PGPASSWORD

      psql --no-psqlrc --quiet \
        --set ON_ERROR_STOP=1 \
        --set principal="$PRINCIPAL_NAME" \
        --set oid="$PRINCIPAL_OID" \
        --set type="$PRINCIPAL_TYPE" \
        --set administrator="$ADMINISTRATOR" <<'SQL'
        SELECT pgaadauth_create_principal_with_oid(:'principal', :'oid', :'type', false, false)
        WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'principal');

        GRANT :"principal" TO :"administrator";
      SQL
    EOT
  }

  depends_on = [
    azurerm_postgresql_flexible_server_active_directory_administrator.this,
    azurerm_postgresql_flexible_server_firewall_rule.this,
  ]
}

resource "postgresql_database" "entra" {
  for_each = local.entra_databases

  name       = each.key
  owner      = each.value.entra_principal.name
  template   = "template0"
  encoding   = each.value.charset
  lc_collate = each.value.collation
  lc_ctype   = each.value.collation

  depends_on = [terraform_data.entra_principal]
}

################################################################################
# Hardening shared by both cases
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
    postgresql_database.password,
    postgresql_database.entra,
  ]
}
