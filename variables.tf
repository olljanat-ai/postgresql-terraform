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

variable "enable_telemetry" {
  description = "Whether the Azure Verified Modules report their usage to Microsoft. The modules do it by attaching a deployment with a module specific identifier to the subscription, which carries no data about the resources themselves. See https://aka.ms/avm/telemetryinfo."
  type        = bool
  default     = true
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
    # makes the database owner have full rights on its own database, and only on
    # that one, without any further grants. On older versions public is owned by
    # the bootstrap superuser and is writable by everybody, so the isolation
    # this configuration promises would not hold.
    condition     = tonumber(var.postgresql_version) >= 15
    error_message = "postgresql_version has to be 15 or newer: on older versions the public schema is writable by every role, so the database would not be isolated."
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

variable "high_availability" {
  description = <<-EOT
    High availability of the server, or null for a server without a standby.

    Not every SKU and region offers it: the burstable SKUs, the `B_` prefixed ones, offer none, so a server on those has to set this to null.
  EOT

  type = object({
    mode                      = string
    standby_availability_zone = optional(string)
  })
  default = {
    mode = "ZoneRedundant"
  }

  validation {
    condition     = var.high_availability == null || contains(["SameZone", "ZoneRedundant"], try(var.high_availability.mode, ""))
    error_message = "high_availability.mode has to be either SameZone or ZoneRedundant."
  }
}

variable "maintenance_window" {
  description = "Window Azure applies its maintenance in, or null to let Azure schedule it. `day_of_week` runs from 0, Sunday, to 6, and the start time is in UTC."
  type = object({
    day_of_week  = optional(string)
    start_hour   = optional(number)
    start_minute = optional(number)
  })
  default = null
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
  description = "Login of the built-in PostgreSQL administrator. Terraform uses it to create the database and its roles."
  type        = string
  default     = "pgadmin"
}

variable "administrator_password" {
  description = "Password of the built-in PostgreSQL administrator. Pass it as TF_VAR_administrator_password so that it stays out of the environment file. The postgresql provider needs it before the server exists, so it cannot be generated here."
  type        = string
  sensitive   = true
}

variable "public_network_access_enabled" {
  description = "Whether the server is reachable from the public internet. Terraform needs network access to the server to manage the database and its roles."
  type        = bool
  default     = true
}

variable "firewall_rule_name" {
  description = "Name of the firewall rule created on the server."
  type        = string
  default     = "terraform"
}

variable "firewall_rule_start_ip_address" {
  description = "First address the firewall rule allows in. Leave it and firewall_rule_end_ip_address unset to create no rule at all, which is what a server reached over a private endpoint wants."
  type        = string
  default     = null
}

variable "firewall_rule_end_ip_address" {
  description = "Last address the firewall rule allows in."
  type        = string
  default     = null

  validation {
    # This used to be a precondition on the server resource, which the module
    # took over. A variable validation may read another variable from Terraform
    # 1.9 onwards, so the pair is checked here instead, and the message names
    # both regardless of which one was left out.
    condition     = (var.firewall_rule_start_ip_address == null) == (var.firewall_rule_end_ip_address == null)
    error_message = "firewall_rule_start_ip_address and firewall_rule_end_ip_address have to be set together, or both left unset."
  }
}

variable "entra_administrator" {
  description = "Entra principal that becomes a Microsoft Entra administrator of the server. Terraform signs in as this principal to mark the workload identity role as an Entra principal, which only an Entra administrator may do, so it has to be the identity Terraform runs as or a group that identity belongs to."
  type = object({
    object_id      = string
    principal_name = string
    principal_type = optional(string, "User")
  })

  validation {
    condition     = contains(["User", "Group", "ServicePrincipal"], var.entra_administrator.principal_type)
    error_message = "entra_administrator.principal_type must be one of User, Group or ServicePrincipal."
  }
}

variable "database_name" {
  description = "Name of the database this configuration creates."
  type        = string
}

variable "database_charset" {
  description = "Encoding of the database."
  type        = string
  default     = "UTF8"
}

variable "database_collation" {
  description = "Collation of the database."
  type        = string
  default     = "en_US.utf8"
}

variable "owner_username" {
  description = "Name of the role that owns the database and authenticates with a generated password. Defaults to <database_name>_owner."
  type        = string
  default     = null
}

variable "owner_login" {
  description = "Whether the owner role itself signs in. Set it to false once the application has moved to the workload identity: the owner role keeps owning the database and everything in it, but it can no longer sign in, and its generated password and Key Vault secret stop existing."
  type        = bool
  default     = true
}

variable "workload_identity_name" {
  description = "Name of the user assigned managed identity this configuration creates for the application. It is also the name of the PostgreSQL role, because that is the name Entra ID resolves when the identity signs in. Defaults to id-<database_name>."
  type        = string
  default     = null

  validation {
    # The name ends up as a PostgreSQL role name as well, and a role name that
    # needs quoting in every statement about it is a nuisance rather than an
    # error, so the safe subset is required here.
    condition     = var.workload_identity_name == null || can(regex("^[a-zA-Z][a-zA-Z0-9-_]{2,127}$", var.workload_identity_name))
    error_message = "workload_identity_name has to be 3 to 128 characters of letters, digits, dashes and underscores, and start with a letter."
  }
}

variable "revoke_public_connect" {
  description = "Revoke the CONNECT privilege of the PUBLIC role on the database, so that only its owner, the workload identity and the administrators can connect to it."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to the resource group, the server, the workload identity and the vault."
  type        = map(string)
  default     = {}
}

variable "key_vault_name" {
  description = "Name of the Azure Key Vault the generated owner password is written to. Has to be globally unique. Leave it unset to skip the vault entirely, in which case the password is only available in the state and through the owner_password output."
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

variable "key_vault_network_acls" {
  description = <<-EOT
    Network ACL of the vault, or null for a vault that accepts every address its public network access allows.

    Terraform writes the secrets over the data plane, so an ACL that denies by default has to list the address Terraform runs from in `ip_rules`.
  EOT

  type = object({
    bypass                     = optional(string, "AzureServices")
    default_action             = optional(string, "Deny")
    ip_rules                   = optional(list(string), [])
    virtual_network_subnet_ids = optional(list(string), [])
  })
  default = null
}

variable "key_vault_rbac_propagation_wait" {
  description = "How long to wait after granting the deployer access to the vault before writing the first secret. A fresh role assignment takes a while to reach the data plane, and a secret written before it is there fails with \"Caller is not authorized to perform action on resource\"."
  type        = string
  default     = "60s"
}

variable "key_vault_grant_deployer_access" {
  description = "Create a Key Vault Secrets Officer role assignment on the vault for the identity Terraform runs as. Creating a vault grants no access to its secrets, so without this the secrets cannot be written. Turn it off when the access is granted outside of this configuration, for example because the identity Terraform runs as may not create role assignments."
  type        = bool
  default     = true
}

variable "key_vault_store_administrator_password" {
  description = "Also store administrator_password in the vault, next to the generated owner password. It is not generated here, but keeping it there makes the vault the single place holding the credentials of the server."
  type        = bool
  default     = true
}
