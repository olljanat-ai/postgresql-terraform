################################################################################
# Key Vault holding the passwords
################################################################################

locals {
  # The module keys secrets by an arbitrary map key rather than by the secret
  # name, so that a name that is only known after an apply does not break the
  # plan. The keys here are prefixed to keep a database called "administrator"
  # from colliding with the administrator secret.
  owner_secret_keys = { for name in keys(local.databases) : name => "owner-${name}" }

  owner_secrets = {
    for name, db in local.databases : local.owner_secret_keys[name] => {
      name         = local.owner_secret_names[name]
      content_type = "PostgreSQL password"

      tags = merge(var.tags, {
        server   = var.server_name
        database = name
        role     = local.owner_role_names[name]
      })
    }
  }

  # The administrator password is passed in rather than generated here, but the
  # vault is where the rest of the credentials of this server live.
  administrator_secret = var.key_vault_store_administrator_password ? {
    administrator = {
      name         = local.administrator_secret_name
      content_type = "PostgreSQL password"

      tags = merge(var.tags, {
        server = var.server_name
        role   = var.administrator_login
      })
    }
  } : {}

  key_vault_secrets = merge(local.owner_secrets, local.administrator_secret)

  key_vault_secret_values = merge(
    { for name, key in local.owner_secret_keys : key => random_password.owner[name].result },
    var.key_vault_store_administrator_password ? { administrator = var.administrator_password } : {},
  )

  # Creating a vault grants no access to the secrets inside it, not even to the
  # identity that created it, so Terraform has to give itself the data plane
  # role that lets it write them.
  key_vault_role_assignments = var.key_vault_grant_deployer_access ? {
    deployer = {
      role_definition_id_or_name = "Key Vault Secrets Officer"
      principal_id               = data.azurerm_client_config.current.object_id
      principal_type             = "User"

      # The role is assigned to the identity Terraform runs as, which exists by
      # definition, so the provider does not have to wait for Entra to
      # replicate it.
      skip_service_principal_aad_check = true

      description = "Lets the Terraform runner write the database passwords."
    }
  } : {}
}

module "key_vault" {
  source  = "Azure/avm-res-keyvault-vault/azurerm"
  version = "0.11.0"

  count = local.key_vault_enabled ? 1 : 0

  name                = var.key_vault_name
  resource_group_name = module.resource_group.name
  location            = module.resource_group.location
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = var.key_vault_sku_name

  soft_delete_retention_days = var.key_vault_soft_delete_retention_days
  purge_protection_enabled   = var.key_vault_purge_protection_enabled

  # Terraform writes the secrets over the data plane, so it needs to reach the
  # vault itself, not only the Azure Resource Manager API. The module denies
  # every address by default, which is why the ACL is always passed.
  public_network_access_enabled = var.key_vault_public_network_access_enabled
  network_acls                  = var.key_vault_network_acls

  # The module uses Azure RBAC rather than the legacy access policies whenever
  # legacy_access_policies_enabled is left off, which is its default.
  role_assignments = local.key_vault_role_assignments

  # A fresh role assignment takes a while to reach the data plane of the vault,
  # and a secret written before it is there fails with "Caller is not
  # authorized to perform action on resource". The module waits 30 seconds by
  # default, which is on the short side for a brand new vault.
  wait_for_rbac_before_secret_operations = {
    create = var.key_vault_rbac_propagation_wait
  }

  secrets       = local.key_vault_secrets
  secrets_value = local.key_vault_secret_values

  enable_telemetry = var.enable_telemetry

  tags = var.tags
}
