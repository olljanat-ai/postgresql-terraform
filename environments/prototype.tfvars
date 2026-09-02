# Prototype environment.
#
# One PostgreSQL flexible server carrying one database, reachable two ways: as
# the owner role with a generated password, and as a Microsoft Entra workload
# identity that is a member of that owner role. Both have the same access, so an
# application can move from the one to the other whenever it is ready.
#
#   terraform apply -var-file=environments/prototype.tfvars
#
# The administrator password is not here on purpose, pass it in the environment:
#
#   export TF_VAR_administrator_password="$(openssl rand -base64 24)"

subscription_id     = "b03f3a19-0547-4c63-a440-ae049cdc2889"
resource_group_name = "rg-postgresql-prototype"
location            = "swedencentral"
server_name         = "psql-prototype-0001"

# Azure offers a different set of PostgreSQL versions per SKU and region, and
# rejects the create with "ParameterOutOfRange: The value of the 'Version'
# should be in: []" when the combination is not offered. This one is known to
# work, list what a region has with:
#
#   az postgres flexible-server list-skus --location swedencentral --output table
postgresql_version = "15"
sku_name           = "B_Standard_B2s"

# The database and the role that owns it. owner_username defaults to
# <database_name>_owner, so leaving it unset would give billing_owner.
database_name  = "billing"
owner_username = "billing_app"

# The generated owner password is written into this Key Vault, in a secret named
# after the owner role. The name has to be globally unique and the vault is
# created into the resource group above.
#
#   az keyvault secret show --vault-name kv-psql-prototype-0001 \
#     --name billing-app --query value -o tsv
#
# Terraform gives itself the Key Vault Secrets Officer role on the vault, which
# needs the identity it runs as to be allowed to create role assignments (Owner
# or User Access Administrator on the resource group or the subscription). Set
# key_vault_grant_deployer_access = false when that access is arranged
# elsewhere, or leave key_vault_name unset to skip the vault altogether.
key_vault_name = "kv-psql-prototype-0001"

# A throwaway environment is meant to be destroyable, and purge protection keeps
# the vault, and its name, reserved for the whole soft delete retention period.
key_vault_purge_protection_enabled   = false
key_vault_soft_delete_retention_days = 7

tags = {
  environment = "prototype"
  managed_by  = "terraform"
}

# Terraform manages the database and its roles over port 5432, so the address it
# runs from has to be allowed in: curl -s https://api.ipify.org
#
# The range below is the whole internet. It is workable for a throwaway
# prototype, where the address Terraform runs from is not known up front, but
# narrow it to that address before this server holds anything real. Leave both
# unset to create no rule at all.
firewall_rule_start_ip_address = "0.0.0.0"
firewall_rule_end_ip_address   = "255.255.255.255"

# Terraform signs in to PostgreSQL as this principal to mark the workload
# identity role below as an Entra identity, with a token of the identity it runs
# as, so this has to be that identity or a group it belongs to. A group is the
# easier of the two, because it keeps working when the identity running
# Terraform changes:
#
#   az ad group show --group sg-postgresql-admins --query id -o tsv
#
# As the signed in user instead (principal_name is the user principal name, and
# principal_type is User):
#   az ad signed-in-user show --query id -o tsv
#   az ad signed-in-user show --query userPrincipalName -o tsv
#
# As a service principal (principal_name is its display name, not its
# application id, and principal_type is ServicePrincipal):
#   az ad sp show --id "$(az account show --query user.name -o tsv)" --query id -o tsv
#   az ad sp show --id "$(az account show --query user.name -o tsv)" --query displayName -o tsv
entra_administrator = {
  object_id      = "9fde82d2-92f3-47dc-bdb3-b07cd4d16b9c"
  principal_name = "psqladmin@olliaditrooutlook.onmicrosoft.com"
  principal_type = "User"
}

# The user assigned managed identity of the application, which this
# configuration creates into the resource group above. Its name is also the name
# of the PostgreSQL role, because that is what Entra ID resolves at sign in.
# Leaving it unset would give id-<database_name>, so id-billing here.
#
# Attaching the identity to whatever runs the application is that workload's own
# deployment:
#
#   terraform output -raw workload_identity_id
#   terraform output -raw workload_identity_client_id
workload_identity_name = "id-billing-app"

# Turn this off once the application signs in as the workload identity only. The
# owner role keeps owning the database and everything in it, but it can no
# longer sign in, and its password and Key Vault secret stop existing.
owner_login = true
