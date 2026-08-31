locals {
  databases = { for db in var.databases : db.name => db }

  owner_role_names = {
    for name, db in local.databases :
    name => coalesce(db.owner_username, "${name}_owner")
  }

  key_vault_enabled = var.key_vault_name != null

  # A Key Vault secret name may only carry letters, digits and dashes, while a
  # PostgreSQL role name commonly carries underscores.
  owner_secret_names = {
    for name, role in local.owner_role_names : name => replace(role, "_", "-")
  }

  administrator_secret_name = replace(var.administrator_login, "_", "-")
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

  authentication = {
    password_auth_enabled         = true
    active_directory_auth_enabled = false
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
  firewall_rules = {
    for name, rule in var.firewall_rules : name => {
      name             = name
      start_ip_address = rule.start_ip_address
      end_ip_address   = rule.end_ip_address
    }
  }

  # The databases are not created here. The module creates them through Azure
  # Resource Manager, which offers no way to say who owns one, and every
  # database in this configuration is owned by a role of its own. They are
  # created over the PostgreSQL wire protocol in databases.tf instead.

  enable_telemetry = var.enable_telemetry

  tags = var.tags
}
