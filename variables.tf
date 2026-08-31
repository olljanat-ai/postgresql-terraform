variable "name" {
  description = "Name of the Azure Database for PostgreSQL flexible server."
  type        = string
}

variable "resource_group_name" {
  description = "Name of the resource group the server is created into."
  type        = string
}

variable "location" {
  description = "Azure region of the server."
  type        = string
}

variable "postgresql_version" {
  description = "Major PostgreSQL version. Version 16 or newer is recommended: from 16 onwards the public schema is owned by pg_database_owner, so a database owner automatically has full rights on it."
  type        = string
  default     = "16"
}

variable "sku_name" {
  description = "SKU of the server, for example B_Standard_B1ms or GP_Standard_D2s_v3."
  type        = string
  default     = "B_Standard_B1ms"
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
  description = "Login of the built-in PostgreSQL administrator. It is used by Terraform to create the databases and their owners."
  type        = string
  default     = "pgadmin"
}

variable "administrator_password" {
  description = "Password of the built-in administrator. A random password is generated when this is null."
  type        = string
  default     = null
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
  description = "Microsoft Entra ID principal that becomes an administrator of the server. Required when any database is owned by an Entra ID identity, because only an Entra administrator can create Entra principals inside PostgreSQL."
  type = object({
    tenant_id      = string
    object_id      = string
    principal_name = string
    principal_type = optional(string, "User")
  })
  default = null

  validation {
    condition     = var.entra_administrator == null || contains(["User", "Group", "ServicePrincipal"], try(var.entra_administrator.principal_type, "User"))
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
      db.entra_principal == null || contains(["user", "group", "service"], db.entra_principal.type)
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
  description = "Tags applied to the server."
  type        = map(string)
  default     = {}
}
