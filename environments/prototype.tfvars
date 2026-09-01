# Prototype environment.
#
# One PostgreSQL flexible server carrying every kind of database this
# configuration supports: owners that authenticate with a username and a
# generated password, and owners that are Microsoft Entra ID identities.
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

# The generated owner passwords are written into this Key Vault, one secret per
# database owner, named after the owner role. The name has to be globally unique
# and it is created into the resource group above.
#
#   az keyvault secret show --vault-name kv-psql-prototype-0001 \
#     --name orders-owner --query value -o tsv
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

# Terraform manages the databases and the roles over port 5432, so the address
# it runs from has to be allowed in: curl -s https://api.ipify.org
#
# The range below is the whole internet. It is workable for a throwaway
# prototype, where the address Terraform runs from is not known up front, but
# narrow it to that address before this server holds anything real.
firewall_rules = {
  terraform = {
    start_ip_address = "0.0.0.0"
    end_ip_address   = "255.255.255.255"
  }
}

# Terraform signs in to PostgreSQL as this principal to mark the roles below as
# Entra identities, with a token of the identity it runs as, so this has to be
# that identity or a group it belongs to. A group is the easier of the two,
# because it keeps working when the identity running Terraform changes:
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

databases = [
  # Username and password owner. The owner role defaults to <database>_owner, so
  # orders_owner here.
  {
    name = "orders"
  },

  # Username and password owner under a name of its own.
  {
    name           = "billing"
    owner_username = "billing_app"
  },

  # Owned by an Entra ID group: everybody in the group gets full access to the
  # database, and nobody needs a password.
  #   az ad group show --group sg-analytics-db-owners --query id -o tsv
  {
    name = "analytics"
    entra_principal = {
      name      = "sg-analytics-db-owners"
      object_id = "f51ee4ed-6c2d-42ee-9ba7-a08814b047ec"
      type      = "group"
    }
  },

  # Owned by the managed identity of a workload.
  #   az identity show --name id-reporting --resource-group rg-reporting --query principalId -o tsv
  {
    name = "reporting"
    entra_principal = {
      name      = "id-reporting"
      object_id = "831b3ba3-03cc-4270-b7e6-5905683c847f"
      type      = "service"
    }
  },
]
