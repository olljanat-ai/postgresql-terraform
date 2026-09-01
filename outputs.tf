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
  description = "Created databases, their owner role, how that owner authenticates and the further roles that are members of it, keyed by database name."
  value = {
    for name, db in local.databases : name => {
      name  = name
      owner = local.owner_role_names[name]
      # An owner with owner_login = false never signs in, it only holds the
      # ownership while its members do.
      authentication = db.entra_principal != null ? "entra-id" : (db.owner_login ? "password" : "none")
      members = [
        for member in db.owner_members : {
          name           = member.name
          authentication = member.entra_principal == null ? "password" : "entra-id"
        }
      ]
    }
  }
}

# Which role to sign in as, how it authenticates and where its password is, for
# every role this configuration creates, flattened by role name.
output "login_roles" {
  description = "Every role that can sign in, keyed by role name: the database it reaches, whether it owns that database or is a member of its owner, how it authenticates and the name of the Key Vault secret holding its password."
  value = merge(
    {
      for name, db in local.databases : local.owner_role_names[name] => {
        database       = name
        membership     = "owner"
        authentication = db.entra_principal != null ? "entra-id" : "password"
        secret         = local.key_vault_enabled && db.entra_principal == null ? local.owner_secret_names[name] : null
      } if db.entra_principal != null || db.owner_login
    },
    {
      for key, member in local.owner_members : member.name => {
        database       = member.database
        membership     = "member"
        authentication = member.entra_principal == null ? "password" : "entra-id"
        secret         = local.key_vault_enabled && member.entra_principal == null ? local.member_secret_names[key] : null
      }
    },
  )
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

output "member_passwords" {
  description = "Generated passwords of the password authenticated owner_members, keyed by role name."
  value       = { for key, member in local.password_members : member.name => random_password.member[key].result }
  sensitive   = true
}

output "member_password_secrets" {
  description = "Name of the Key Vault secret holding the password of each password authenticated owner_member, keyed by role name. Empty when no vault is created."
  value       = { for key, secret in azurerm_key_vault_secret.member : local.owner_members[key].name => secret.name }
}

output "administrator_password_secret" {
  description = "Name of the Key Vault secret holding the administrator password, or null when it is not stored in the vault."
  value       = one(azurerm_key_vault_secret.administrator[*].name)
}
