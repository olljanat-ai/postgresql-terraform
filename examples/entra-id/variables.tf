variable "subscription_id" {
  description = "Azure subscription the resources are created into."
  type        = string
}

variable "resource_group_name" {
  description = "Name of the resource group created by this example."
  type        = string
  default     = "rg-postgresql-entra-id"
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
  description = "Login of the built-in PostgreSQL administrator. Terraform uses it to create the databases, the application identities do not need it."
  type        = string
  default     = "pgadmin"
}

variable "administrator_password" {
  description = "Password of the built-in PostgreSQL administrator."
  type        = string
  sensitive   = true
}

variable "client_ip_address" {
  description = "Public IP address Terraform runs from."
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

variable "orders_group_name" {
  description = "Display name of the Entra group that owns the orders database."
  type        = string
}

variable "orders_group_object_id" {
  description = "Object id of the Entra group that owns the orders database."
  type        = string
}

variable "billing_identity_name" {
  description = "Display name of the managed identity that owns the billing database."
  type        = string
}

variable "billing_identity_object_id" {
  description = "Object id (not the client id) of the managed identity that owns the billing database."
  type        = string
}
