variable "subscription_id" {
  description = "Azure subscription the prototype is created into."
  type        = string
}

variable "resource_group_name" {
  description = "Name of the resource group created by this environment."
  type        = string
  default     = "rg-postgresql-prototype"
}

variable "location" {
  description = "Azure region."
  type        = string
  default     = "westeurope"
}

variable "server_name" {
  description = "Name of the PostgreSQL flexible server. Has to be globally unique."
  type        = string
}

variable "administrator_login" {
  description = "Login of the built-in PostgreSQL administrator. Terraform uses it to create the databases and their owners."
  type        = string
  default     = "pgadmin"
}

variable "administrator_password" {
  description = "Password of the built-in PostgreSQL administrator. It is passed in instead of being generated, so that the postgresql provider can be configured before the server exists."
  type        = string
  sensitive   = true
}

variable "client_ip_address" {
  description = "Public IP address Terraform runs from. It is allowed through the server firewall so that the databases and the roles can be managed."
  type        = string
}

variable "entra_administrator_object_id" {
  description = "Object id of the Entra identity that becomes the administrator of the server. This is the identity the Azure CLI is logged in as."
  type        = string
}

variable "entra_administrator_principal_name" {
  description = "User principal name, or display name for a group or a service principal, of the Entra administrator."
  type        = string
}

variable "entra_administrator_principal_type" {
  description = "Type of the Entra administrator: User, Group or ServicePrincipal."
  type        = string
  default     = "User"
}

variable "analytics_group_name" {
  description = "Display name of the Entra group that owns the analytics database."
  type        = string
}

variable "analytics_group_object_id" {
  description = "Object id of the Entra group that owns the analytics database."
  type        = string
}

variable "reporting_identity_name" {
  description = "Display name of the managed identity that owns the reporting database."
  type        = string
}

variable "reporting_identity_object_id" {
  description = "Object id (not the client id) of the managed identity that owns the reporting database."
  type        = string
}
