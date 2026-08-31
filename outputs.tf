output "resource_group_name" {
  description = "Name of the resource group."
  value       = module.resource_group.name
}

output "server_id" {
  description = "Resource id of the PostgreSQL flexible server."
  value       = module.postgresql_server.resource_id
}

output "server_name" {
  description = "Name of the PostgreSQL flexible server."
  value       = module.postgresql_server.name
}

output "fqdn" {
  description = "Host name of the PostgreSQL flexible server."
  value       = module.postgresql_server.fqdn
}

output "administrator_login" {
  description = "Login of the built-in PostgreSQL administrator."
  value       = var.administrator_login
}

output "databases" {
  description = "Created databases and their owner role, keyed by database name."
  value = {
    for name, db in local.databases : name => {
      name  = name
      owner = postgresql_role.owner[name].name
    }
  }
}

output "owner_passwords" {
  description = "Generated passwords of the database owners, keyed by database name."
  value       = { for name, password in random_password.owner : name => password.result }
  sensitive   = true
}

output "key_vault_id" {
  description = "Resource id of the Key Vault holding the passwords, or null when no vault is created."
  value       = one(module.key_vault[*].resource_id)
}

output "key_vault_name" {
  description = "Name of the Key Vault holding the passwords, or null when no vault is created."
  value       = one(module.key_vault[*].name)
}

output "key_vault_uri" {
  description = "Data plane URI of the Key Vault holding the passwords, or null when no vault is created."
  value       = one(module.key_vault[*].uri)
}

output "owner_password_secrets" {
  description = "Name of the Key Vault secret holding the password of each database owner, keyed by database name. Empty when no vault is created."
  value = local.key_vault_enabled ? {
    for name, key in local.owner_secret_keys : name => module.key_vault[0].secrets_resource_ids[key].name
  } : {}
}

output "administrator_password_secret" {
  description = "Name of the Key Vault secret holding the administrator password, or null when it is not stored in the vault."
  value       = local.key_vault_enabled && var.key_vault_store_administrator_password ? module.key_vault[0].secrets_resource_ids["administrator"].name : null
}
