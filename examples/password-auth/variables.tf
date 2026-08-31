variable "subscription_id" {
  description = "Azure subscription the resources are created into."
  type        = string
}

variable "resource_group_name" {
  description = "Name of the resource group created by this example."
  type        = string
  default     = "rg-postgresql-password-auth"
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
  description = "Login of the built-in PostgreSQL administrator."
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
