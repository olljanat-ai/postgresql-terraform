output "fqdn" {
  description = "Host name of the PostgreSQL server."
  value       = module.postgresql.fqdn
}

output "databases" {
  description = "Created databases, their owner and how that owner authenticates."
  value       = module.postgresql.databases
}

output "owner_passwords" {
  description = "Generated passwords of the password authenticated owners. Read with: terraform output -json owner_passwords"
  value       = module.postgresql.owner_passwords
  sensitive   = true
}
