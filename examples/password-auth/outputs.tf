output "fqdn" {
  description = "Host name of the PostgreSQL server."
  value       = module.postgresql.fqdn
}

output "databases" {
  description = "Created databases and their owners."
  value       = module.postgresql.databases
}

output "owner_passwords" {
  description = "Generated passwords of the database owners. Read with: terraform output -json owner_passwords"
  value       = module.postgresql.owner_passwords
  sensitive   = true
}
