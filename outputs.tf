output "resource_group_name" {
  description = "Name of the resource group."
  value       = azurerm_resource_group.this.name
}

output "server_id" {
  description = "Resource id of the PostgreSQL flexible server."
  value       = azurerm_postgresql_flexible_server.this.id
}

output "server_name" {
  description = "Name of the PostgreSQL flexible server."
  value       = azurerm_postgresql_flexible_server.this.name
}

output "fqdn" {
  description = "Host name of the PostgreSQL flexible server."
  value       = azurerm_postgresql_flexible_server.this.fqdn
}

output "administrator_login" {
  description = "Login of the built-in PostgreSQL administrator."
  value       = var.administrator_login
}

output "database_name" {
  description = "Name of the created database."
  value       = postgresql_database.this.name
}

output "owner_role" {
  description = "Role that owns the database. It signs in with a generated password while owner_login is on, and only holds the ownership once it is off."
  value       = postgresql_role.owner.name
}

output "owner_login_enabled" {
  description = "Whether the owner role can sign in, or whether the workload identity is the only way into the database."
  value       = var.owner_login
}

output "workload_identity_role" {
  description = "Role the Microsoft Entra workload identity signs in as. It is a member of the owner role, so it has the same access to the database, and it authenticates with an access token instead of a password."
  value       = postgresql_role.workload_identity.name
}

output "owner_password" {
  description = "Generated password of the owner role, or null when owner_login is off."
  value       = one(random_password.owner[*].result)
  sensitive   = true
}

output "key_vault_id" {
  description = "Resource id of the Key Vault holding the passwords, or null when no vault is created."
  value       = one(azurerm_key_vault.this[*].id)
}

output "key_vault_name" {
  description = "Name of the Key Vault holding the passwords, or null when no vault is created."
  value       = one(azurerm_key_vault.this[*].name)
}

output "key_vault_uri" {
  description = "Data plane URI of the Key Vault holding the passwords, or null when no vault is created."
  value       = one(azurerm_key_vault.this[*].vault_uri)
}

output "owner_password_secret" {
  description = "Name of the Key Vault secret holding the owner password, or null when there is no vault or the owner does not sign in."
  value       = one(azurerm_key_vault_secret.owner[*].name)
}

output "administrator_password_secret" {
  description = "Name of the Key Vault secret holding the administrator password, or null when it is not stored in the vault."
  value       = one(azurerm_key_vault_secret.administrator[*].name)
}
