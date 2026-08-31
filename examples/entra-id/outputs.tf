output "fqdn" {
  description = "Host name of the PostgreSQL server."
  value       = module.postgresql.fqdn
}

output "databases" {
  description = "Created databases and their Entra ID owners."
  value       = module.postgresql.databases
}
