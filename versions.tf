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
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5"
    }
  }

  # The state holds the generated owner passwords, so anything that outlives a
  # single laptop belongs in a remote backend.
  #
  # backend "azurerm" {
  #   resource_group_name  = "rg-tfstate"
  #   storage_account_name = "sttfstate"
  #   container_name       = "tfstate"
  #   key                  = "postgresql.tfstate"
  # }
}

provider "azurerm" {
  features {}

  subscription_id = var.subscription_id
}

# The server does not exist yet when the provider is configured, so the host
# cannot be read from the server resource. The name of a flexible server fully
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
