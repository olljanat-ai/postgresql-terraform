# Prototype environment.
#
# One PostgreSQL flexible server carrying every kind of database the root
# module supports: databases whose owner authenticates with a username and a
# generated password, and databases whose owner is a Microsoft Entra ID
# identity.

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.0"
    }
    postgresql = {
      source  = "cyrilgdn/postgresql"
      version = ">= 1.22"
    }
  }

  # The state holds the generated owner passwords, so a prototype that outlives
  # a single laptop belongs in a remote backend.
  #
  # backend "azurerm" {
  #   resource_group_name  = "rg-tfstate"
  #   storage_account_name = "sttfstate"
  #   container_name       = "tfstate"
  #   key                  = "postgresql-prototype.tfstate"
  # }
}

provider "azurerm" {
  features {}

  subscription_id = var.subscription_id
}

# The server does not exist yet when the provider is configured, so the host
# cannot be read from a module output. The name of a flexible server fully
# determines its FQDN, which lets the provider be configured up front and the
# whole environment be applied in one run.
provider "postgresql" {
  host      = "${var.server_name}.postgres.database.azure.com"
  port      = 5432
  username  = var.administrator_login
  password  = var.administrator_password
  sslmode   = "require"
  superuser = false
}

data "azurerm_client_config" "current" {}

resource "azurerm_resource_group" "prototype" {
  name     = var.resource_group_name
  location = var.location

  tags = local.tags
}

locals {
  tags = {
    environment = "prototype"
    managed_by  = "terraform"
  }
}

module "postgresql" {
  source = "../../"

  name                = var.server_name
  resource_group_name = azurerm_resource_group.prototype.name
  location            = azurerm_resource_group.prototype.location

  administrator_login    = var.administrator_login
  administrator_password = var.administrator_password

  # The Entra administrator is the identity that creates the Entra principals
  # inside PostgreSQL, so it has to be the identity the Azure CLI is logged in
  # as while Terraform runs.
  entra_administrator = {
    tenant_id      = data.azurerm_client_config.current.tenant_id
    object_id      = var.entra_administrator_object_id
    principal_name = var.entra_administrator_principal_name
    principal_type = var.entra_administrator_principal_type
  }

  firewall_rules = {
    terraform = {
      start_ip_address = var.client_ip_address
      end_ip_address   = var.client_ip_address
    }
  }

  databases = [
    # Username and password owner. The owner defaults to <database>_owner, so
    # orders_owner here.
    {
      name = "orders"
    },

    # Username and password owner under a name of its own.
    {
      name           = "billing"
      owner_username = "billing_app"
    },

    # Owned by an Entra ID group: everybody in the group gets full access to
    # the database, and nobody needs a password.
    {
      name = "analytics"
      entra_principal = {
        name      = var.analytics_group_name
        object_id = var.analytics_group_object_id
        type      = "group"
      }
    },

    # Owned by the managed identity of a workload.
    {
      name = "reporting"
      entra_principal = {
        name      = var.reporting_identity_name
        object_id = var.reporting_identity_object_id
        type      = "service"
      }
    },
  ]

  tags = local.tags
}
