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

module "resource_group" {
  source  = "Azure/avm-res-resources-resourcegroup/azurerm"
  version = "0.4.0"

  name     = var.resource_group_name
  location = var.location

  enable_telemetry = var.enable_telemetry

  tags = var.tags
}

module "postgresql_server" {
  source  = "Azure/avm-res-dbforpostgresql-flexibleserver/azurerm"
  version = "0.2.3"

  name                = var.server_name
  resource_group_name = module.resource_group.name
  location            = module.resource_group.location

  server_version    = var.postgresql_version
  sku_name          = var.sku_name
  storage_mb        = var.storage_mb
  zone              = var.zone
  auto_grow_enabled = true

  administrator_login    = var.administrator_login
  administrator_password = var.administrator_password

  # Password authentication stays on alongside Entra ID: Terraform creates the
  # database and the roles as the built-in administrator, which has no Entra
  # identity behind it.
  authentication = {
    password_auth_enabled         = true
    active_directory_auth_enabled = true
    tenant_id                     = data.azurerm_client_config.current.tenant_id
  }

  ad_administrator = {
    this = {
      tenant_id      = data.azurerm_client_config.current.tenant_id
      object_id      = var.entra_administrator.object_id
      principal_name = var.entra_administrator.principal_name
      principal_type = var.entra_administrator.principal_type
    }
  }

  backup_retention_days         = var.backup_retention_days
  public_network_access_enabled = var.public_network_access_enabled

  # The module defaults to a zone redundant standby, which the burstable SKUs
  # do not offer, and to a maintenance window on Sunday at midnight UTC. Both
  # are variables here so that an environment file decides.
  high_availability  = var.high_availability
  maintenance_window = var.maintenance_window

  # The module ships an AllowAllFireWallRule covering the whole internet as the
  # default of this variable, so it is always passed, empty map included.
  firewall_rules = local.firewall_rule_enabled ? {
    this = {
      name             = var.firewall_rule_name
      start_ip_address = var.firewall_rule_start_ip_address
      end_ip_address   = var.firewall_rule_end_ip_address
    }
  } : {}

  # The database is not created here. See the comment on postgresql_database in
  # database.tf: a database created over the Azure Resource Manager API, which
  # is what this module's databases input does, belongs to the role the control
  # plane runs as, and the owner is the whole point of this configuration.

  enable_telemetry = var.enable_telemetry

  tags = var.tags
}

# The user assigned managed identity of the application. It is created here
# rather than passed in, so that the identity, the PostgreSQL role and the label
# tying the two together are one unit: there is no object id to copy between
# configurations and no way for them to drift apart.
#
# Attaching it to whatever runs the application, a virtual machine, an App
# Service or an AKS workload, is that workload's own deployment. The identity
# and its client id are outputs for exactly that.
module "workload_identity" {
  source  = "Azure/avm-res-managedidentity-userassignedidentity/azurerm"
  version = "0.5.2"

  name                = local.workload_identity_name
  resource_group_name = module.resource_group.name
  location            = module.resource_group.location

  enable_telemetry = var.enable_telemetry

  tags = var.tags
}
