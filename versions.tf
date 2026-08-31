terraform {
  required_version = ">= 1.3.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 3.90"
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
}
