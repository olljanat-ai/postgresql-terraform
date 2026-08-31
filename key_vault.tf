################################################################################
# Key Vault holding the passwords
################################################################################

resource "azurerm_key_vault" "this" {
  count = local.key_vault_enabled ? 1 : 0

  name                = var.key_vault_name
  resource_group_name = module.resource_group.name
  location            = module.resource_group.location
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
  for_each = local.key_vault_enabled ? local.databases : {}

  name         = local.owner_secret_names[each.key]
  value        = random_password.owner[each.key].result
  key_vault_id = azurerm_key_vault.this[0].id
  content_type = "PostgreSQL password"

  tags = merge(var.tags, {
    server   = module.postgresql_server.name
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
    server = module.postgresql_server.name
    role   = var.administrator_login
  })

  depends_on = [time_sleep.key_vault_role_assignment]
}
