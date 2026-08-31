# Two databases, each of them owned by its own PostgreSQL role that
# authenticates with a username and a generated password.

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

# The server is not created yet when the provider is configured, so the host
# cannot be read from a module output. The name of a flexible server fully
# determines its FQDN, which lets the provider be configured up front and the
# whole example be applied in one run.
provider "postgresql" {
  host      = "${var.server_name}.postgres.database.azure.com"
  port      = 5432
  username  = var.administrator_login
  password  = var.administrator_password
  sslmode   = "require"
  superuser = false
}

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

  firewall_rules = {
    terraform = {
      start_ip_address = var.client_ip_address
      end_ip_address   = var.client_ip_address
    }
  }

  databases = [
    # The owner defaults to <database>_owner, so orders_owner here.
    {
      name = "orders"
    },
    {
      name           = "billing"
      owner_username = "billing_app"
    },
  ]
}
