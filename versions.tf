terraform {
  # The AVM Key Vault module requires 1.11, the other three 1.9, so the
  # strictest of them sets the floor here.
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
    # 1.25 is the first release carrying postgresql_security_label, which is how
    # a role is turned into a Microsoft Entra principal here.
    postgresql = {
      source  = "cyrilgdn/postgresql"
      version = ">= 1.25"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5"
    }
  }

  # The state holds the generated owner password in cleartext even when it is
  # also written to the Key Vault, so anything that outlives a single laptop
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
# azurerm instead of being left to fall back to the Azure CLI default. The time
# provider is gone: the Key Vault module owns the RBAC propagation wait now.
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

# Marking a role as a Microsoft Entra principal is a SECURITY LABEL statement,
# and only a Microsoft Entra administrator of the server may run it, so that one
# statement goes over a second connection that signs in with an Entra access
# token. The provider asks for the token itself, through the same credential
# chain the azurerm provider uses, so nothing here shells out to psql or to the
# Azure CLI.
provider "postgresql" {
  alias = "entra"

  host      = "${var.server_name}.postgres.database.azure.com"
  port      = 5432
  sslmode   = "require"
  superuser = false

  username = var.entra_administrator.principal_name

  azure_identity_auth = true
  azure_tenant_id     = data.azurerm_client_config.current.tenant_id
}
