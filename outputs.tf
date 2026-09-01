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

output "databases" {
  description = "Created databases, their owner role and how that owner authenticates, keyed by database name."
  value = {
    for name, db in local.databases : name => {
      name           = name
      owner          = local.owner_role_names[name]
      authentication = db.entra_principal == null ? "password" : "entra-id"
    }
  }
}

output "owner_passwords" {
  description = "Generated passwords of the database owners, keyed by database name. Only holds the databases whose owner authenticates with a username and a password."
  value       = { for name, password in random_password.owner : name => password.result }
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

output "owner_password_secrets" {
  description = "Name of the Key Vault secret holding the password of each database owner, keyed by database name. Empty when no vault is created."
  value       = { for name, secret in azurerm_key_vault_secret.owner : name => secret.name }
}

output "administrator_password_secret" {
  description = "Name of the Key Vault secret holding the administrator password, or null when it is not stored in the vault."
  value       = one(azurerm_key_vault_secret.administrator[*].name)
}
