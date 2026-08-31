locals {
  databases          = { for db in var.databases : db.name => db }
  password_databases = { for name, db in local.databases : name => db if db.entra_principal == null }
  entra_databases    = { for name, db in local.databases : name => db if db.entra_principal != null }

  owner_role_names = {
    for name, db in local.password_databases :
    name => coalesce(db.owner_username, "${name}_owner")
  }

  entra_auth_enabled = var.entra_administrator != null
  key_vault_enabled  = var.key_vault_name != null

  # A Key Vault secret name may only carry letters, digits and dashes, while a
  # PostgreSQL role name commonly carries underscores.
  owner_secret_names = {
    for name, role in local.owner_role_names : name => replace(role, "_", "-")
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

  administrator_login    = var.administrator_login
  administrator_password = var.administrator_password

  backup_retention_days         = var.backup_retention_days
  public_network_access_enabled = var.public_network_access_enabled

  authentication {
    password_auth_enabled         = true
    active_directory_auth_enabled = local.entra_auth_enabled
    tenant_id                     = local.entra_auth_enabled ? data.azurerm_client_config.current.tenant_id : null
  }

  zone = var.zone

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
  resource_group_name = azurerm_resource_group.this.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
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

  name     = local.owner_role_names[each.key]
  login    = true
  password = random_password.owner[each.key].result

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
  for_each = local.password_databases

  role       = var.administrator_login
  grant_role = postgresql_role.owner[each.key].name

  # The administrator created the role, so it is already its grantor and cannot
  # be granted the admin option back.
  with_admin_option = false
}

resource "postgresql_database" "password" {
  for_each = local.password_databases

  depends_on = [postgresql_grant_role.owner_to_administrator]

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
# then granted to the built-in administrator with the admin option, so that
# Terraform can hand the ownership of the database over to it and keep managing
# the privileges of the database afterwards.
resource "terraform_data" "entra_principal" {
  # Guarded so that a missing entra_administrator is reported by the
  # precondition of the server instead of as a null attribute error here.
  for_each = local.entra_auth_enabled ? local.entra_databases : {}

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
      PGHOST              = azurerm_postgresql_flexible_server.this.fqdn
      PGUSER              = var.entra_administrator.principal_name
      PGDATABASE          = "postgres"
      PGSSLMODE           = "require"
      ENTRA_ADMINISTRATOR = var.entra_administrator.principal_name
      ADMINISTRATOR       = var.administrator_login
      PRINCIPAL_NAME      = each.value.entra_principal.name
      PRINCIPAL_OID       = each.value.entra_principal.object_id
      PRINCIPAL_TYPE      = each.value.entra_principal.type
    }

    command = <<-EOT
      set -euo pipefail

      # Only a token of the identity the Azure CLI is signed in as can be
      # requested here, and PostgreSQL rejects a token whose type does not match
      # the role it is presented for, with "is neither an
      # AAD_AUTH_TOKENTYPE_APP_USER or an AAD_AUTH_TOKENTYPE_APP_OBO token".
      # So the signed in identity has to be the Entra administrator itself.
      if ! signed_in_type="$(az account show --query user.type --output tsv 2>/dev/null)"; then
        echo "The Azure CLI is not signed in. Run: az login" >&2
        exit 1
      fi

      signed_in_name="$(az account show --query user.name --output tsv)"
      if [ "$signed_in_type" = "servicePrincipal" ]; then
        # A service principal signs in with its application id, but PostgreSQL
        # knows it by its display name.
        signed_in_name="$(az ad sp show --id "$signed_in_name" \
          --query displayName --output tsv 2>/dev/null || echo "$signed_in_name")"
      fi

      if [ "$signed_in_name" != "$ENTRA_ADMINISTRATOR" ]; then
        echo "The Azure CLI is signed in as '$signed_in_name' ($signed_in_type), but the Entra administrator of the server is '$ENTRA_ADMINISTRATOR'." >&2
        echo "Only an Entra administrator may create Entra principals, and only a token of the signed in identity can be requested here, so the two have to be the same identity." >&2
        echo "Either sign in as '$ENTRA_ADMINISTRATOR', or point entra_administrator at the identity Terraform runs as." >&2
        exit 1
      fi

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

        GRANT :"principal" TO :"administrator" WITH ADMIN OPTION;
      SQL
    EOT
  }

  depends_on = [
    azurerm_postgresql_flexible_server.this,
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
  for_each = local.key_vault_enabled ? local.password_databases : {}

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
