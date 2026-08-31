variable "subscription_id" {
  description = "Azure subscription the resources are created into."
  type        = string
}

variable "resource_group_name" {
  description = "Name of the resource group, which is created by this configuration."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
  default     = "swedencentral"
}

variable "server_name" {
  description = "Name of the Azure Database for PostgreSQL flexible server. Has to be globally unique."
  type        = string
}

variable "postgresql_version" {
  description = "Major PostgreSQL version. Not every version is offered for every SKU and region, check with: az postgres flexible-server list-skus --location <region>"
  type        = string
  default     = "15"

  validation {
    # From PostgreSQL 15 onwards the public schema is owned by
    # pg_database_owner and PUBLIC no longer has CREATE on it, which is what
    # makes a database owner have full rights on its own database, and only on
    # that one, without any further grants. On older versions public is owned by
    # the bootstrap superuser and is writable by everybody, so the isolation
    # this configuration promises would not hold.
    condition     = tonumber(var.postgresql_version) >= 15
    error_message = "postgresql_version has to be 15 or newer: on older versions the public schema is writable by every role, so the databases would not be isolated from each other."
  }
}

variable "sku_name" {
  description = "SKU of the server, for example B_Standard_B1ms or GP_Standard_D2s_v3."
  type        = string
  default     = "B_Standard_B2s"
}

variable "zone" {
  description = "Availability zone the server is placed in. Pinning it keeps Azure from moving the server to another zone on a later apply."
  type        = string
  default     = "1"
}

variable "storage_mb" {
  description = "Storage allocated for the server, in megabytes."
  type        = number
  default     = 32768
}

variable "backup_retention_days" {
  description = "Number of days backups are kept."
  type        = number
  default     = 7
}

variable "administrator_login" {
  description = "Login of the built-in PostgreSQL administrator. Terraform uses it to create the databases and their owners."
  type        = string
  default     = "pgadmin"
}

variable "administrator_password" {
  description = "Password of the built-in PostgreSQL administrator. Pass it as TF_VAR_administrator_password so that it stays out of the environment file. The postgresql provider needs it before the server exists, so it cannot be generated here."
  type        = string
  sensitive   = true
}

variable "public_network_access_enabled" {
  description = "Whether the server is reachable from the public internet. Terraform needs network access to the server to manage databases and roles."
  type        = bool
  default     = true
}

variable "firewall_rules" {
  description = "Firewall rules to create on the server, keyed by rule name. At least the address Terraform runs from has to be allowed when public network access is used."
  type = map(object({
    start_ip_address = string
    end_ip_address   = string
  }))
  default = {}
}

variable "entra_administrator" {
  description = "Microsoft Entra ID principal that becomes an administrator of the server. Required when any database is owned by an Entra ID identity. This has to be the very identity the Azure CLI is signed in as while Terraform runs: only an Entra administrator may create Entra principals, and only a token of the signed in identity can be requested, so a different identity here fails the apply. principal_name is the user principal name of a user and the display name of a group or a service principal."
  type = object({
    object_id      = string
    principal_name = string
    principal_type = optional(string, "User")
  })
  default = null

  validation {
    condition     = contains(["User", "Group", "ServicePrincipal"], try(var.entra_administrator.principal_type, "User"))
    error_message = "entra_administrator.principal_type must be one of User, Group or ServicePrincipal."
  }
}

variable "databases" {
  description = <<-EOT
    Databases to create. Every database gets its own owner, which has full permissions on that database and no permissions on the other ones.

    The owner is either a PostgreSQL role authenticated with a username and a generated password (the default), or a Microsoft Entra ID identity when `entra_principal` is set. `entra_principal.name` is the Entra display name for a group or service principal and the user principal name for a user, and `entra_principal.object_id` is its Entra object id.
  EOT

  type = list(object({
    name           = string
    charset        = optional(string, "UTF8")
    collation      = optional(string, "en_US.utf8")
    owner_username = optional(string)
    entra_principal = optional(object({
      name      = string
      object_id = string
      type      = optional(string, "user")
    }))
  }))
  default = []

  validation {
    condition     = length(distinct([for db in var.databases : db.name])) == length(var.databases)
    error_message = "Database names must be unique."
  }

  validation {
    condition = alltrue([
      for db in var.databases :
      contains(["user", "group", "service"], try(db.entra_principal.type, "user"))
    ])
    error_message = "databases[*].entra_principal.type must be one of user, group or service."
  }
}

variable "revoke_public_connect" {
  description = "Revoke the CONNECT privilege of the PUBLIC role on every managed database, so that only the database owner and the administrators can connect to it."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to the resource group and the server."
  type        = map(string)
  default     = {}
}

variable "key_vault_name" {
  description = "Name of the Azure Key Vault the generated owner passwords are written to. Has to be globally unique. Leave it unset to skip the vault entirely, in which case the passwords are only available in the state and through the owner_passwords output."
  type        = string
  default     = null

  validation {
    condition     = var.key_vault_name == null || can(regex("^[a-zA-Z][a-zA-Z0-9-]{1,22}[a-zA-Z0-9]$", var.key_vault_name))
    error_message = "key_vault_name has to be 3 to 24 characters of letters, digits and dashes, start with a letter and not end with a dash."
  }
}

variable "key_vault_sku_name" {
  description = "SKU of the Key Vault, standard or premium."
  type        = string
  default     = "standard"

  validation {
    condition     = contains(["standard", "premium"], var.key_vault_sku_name)
    error_message = "key_vault_sku_name must be either standard or premium."
  }
}

variable "key_vault_soft_delete_retention_days" {
  description = "Number of days a deleted vault and its secrets can still be recovered. Azure allows 7 to 90 and the value cannot be lowered later."
  type        = number
  default     = 7

  validation {
    condition     = var.key_vault_soft_delete_retention_days >= 7 && var.key_vault_soft_delete_retention_days <= 90
    error_message = "key_vault_soft_delete_retention_days has to be between 7 and 90."
  }
}

variable "key_vault_purge_protection_enabled" {
  description = "Whether a deleted vault is kept for the whole soft delete retention period and cannot be purged before that. Turning it on cannot be undone, and it keeps terraform destroy from freeing the vault name, so it is off by default and belongs on anything that is not a throwaway environment."
  type        = bool
  default     = false
}

variable "key_vault_public_network_access_enabled" {
  description = "Whether the vault is reachable from the public internet. Terraform writes the secrets over the data plane, so it needs network access to the vault."
  type        = bool
  default     = true
}

variable "key_vault_grant_deployer_access" {
  description = "Create a Key Vault Secrets Officer role assignment on the vault for the identity Terraform runs as. Creating a vault grants no access to its secrets, so without this the secrets cannot be written. Turn it off when the access is granted outside of this configuration, for example because the identity Terraform runs as may not create role assignments."
  type        = bool
  default     = true
}

variable "key_vault_store_administrator_password" {
  description = "Also store administrator_password in the vault, next to the generated owner passwords. It is not generated here, but keeping it with them makes the vault the single place holding the credentials of the server."
  type        = bool
  default     = true
}
