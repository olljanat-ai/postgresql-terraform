# Two databases, each of them owned by a Microsoft Entra ID identity instead of
# a username and a password. Nothing but the built-in administrator, which
# Terraform itself uses, has a password on this server.

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
}

provider "azurerm" {
  features {}

  subscription_id = var.subscription_id
}

# See the note about the host name in the password-auth example.
provider "postgresql" {
  host      = "${var.server_name}.postgres.database.azure.com"
  port      = 5432
  username  = var.administrator_login
  password  = var.administrator_password
  sslmode   = "require"
  superuser = false
}

data "azurerm_client_config" "current" {}

resource "azurerm_resource_group" "example" {
  name     = var.resource_group_name
  location = var.location
}

module "postgresql" {
  source = "../../"

  name                = var.server_name
  resource_group_name = azurerm_resource_group.example.name
  location            = azurerm_resource_group.example.location

  administrator_login    = var.administrator_login
  administrator_password = var.administrator_password

  # The Entra administrator is the identity that creates the Entra principals
  # inside PostgreSQL, so it has to be the identity Terraform and the Azure CLI
  # are logged in as.
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
    # Owned by a group: everybody in the group gets full access to the database.
    {
      name = "orders"
      entra_principal = {
        name      = var.orders_group_name
        object_id = var.orders_group_object_id
        type      = "group"
      }
    },
    # Owned by a managed identity of an application.
    {
      name = "billing"
      entra_principal = {
        name      = var.billing_identity_name
        object_id = var.billing_identity_object_id
        type      = "service"
      }
    },
  ]
}
