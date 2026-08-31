terraform {
  # The AVM Key Vault module requires 1.11, the resource group and PostgreSQL
  # modules 1.9, so the strictest of the three sets the floor here.
  required_version = ">= 1.11.0, < 2.0.0"

  required_providers {
    # Used by the AVM resource group module, which creates the group through
    # the Azure Resource Manager API directly rather than through azurerm.
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.4"
    }
    # The AVM PostgreSQL module allows ~> 4.12 and the Key Vault module
    # >= 4.81, < 5.1, so the overlap is >= 4.81 and below 5.0.
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.81.0, < 5.0.0"
    }
    postgresql = {
      source  = "cyrilgdn/postgresql"
      version = ">= 1.22"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5"
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.9"
    }
  }

  # The state holds the generated owner passwords in cleartext even when they
  # are also written to the Key Vault, so anything that outlives a single laptop
  # belongs in a remote backend.
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

# The AVM modules pull in azapi, either directly or through the shared AVM
# interface module, so it is configured against the same subscription as
# azurerm instead of being left to fall back to the Azure CLI default.
provider "azapi" {
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
