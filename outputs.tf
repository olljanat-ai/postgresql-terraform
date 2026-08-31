output "server_id" {
  description = "Resource id of the PostgreSQL flexible server."
  value       = azurerm_postgresql_flexible_server.this.id
}

output "server_name" {
  description = "Name of the PostgreSQL flexible server."
  value       = azurerm_postgresql_flexible_server.this.name
}

output "fqdn" {
  description = "Fully qualified domain name of the PostgreSQL flexible server."
  value       = azurerm_postgresql_flexible_server.this.fqdn
}

output "administrator_login" {
  description = "Login of the built-in PostgreSQL administrator."
  value       = var.administrator_login
}

output "administrator_password" {
  description = "Password of the built-in PostgreSQL administrator."
  value       = local.administrator_password
  sensitive   = true
}

output "databases" {
  description = "Created databases, keyed by database name."
  value = {
    for name, db in local.databases : name => {
      name           = name
      authentication = db.entra_principal == null ? "password" : "entra-id"
      owner = db.entra_principal == null ? (
        postgresql_role.owner[name].name
        ) : (
        db.entra_principal.name
      )
    }
  }
}

output "owner_passwords" {
  description = "Generated passwords of the database owners, keyed by database name. Only contains the databases that use username and password authentication."
  value       = { for name, password in random_password.owner : name => password.result }
  sensitive   = true
}
