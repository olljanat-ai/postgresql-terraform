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

tags = {
  environment = "prototype"
  managed_by  = "terraform"
}

# Terraform manages the databases and the roles over port 5432, so the address
# it runs from has to be allowed in: curl -s https://api.ipify.org
firewall_rules = {
  terraform = {
    start_ip_address = "203.0.113.10"
    end_ip_address   = "203.0.113.10"
  }
}

# The identity the Azure CLI is logged in as while Terraform runs. Only an Entra
# administrator of the server can create the Entra principals below.
#   az ad signed-in-user show --query id -o tsv
#   az ad signed-in-user show --query userPrincipalName -o tsv
entra_administrator = {
  object_id      = "11111111-1111-1111-1111-111111111111"
  principal_name = "you@example.com"
  principal_type = "User"
}

databases = [
  # Username and password owner. The owner defaults to <database>_owner, so
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
      object_id = "22222222-2222-2222-2222-222222222222"
      type      = "group"
    }
  },

  # Owned by the managed identity of a workload.
  #   az identity show --name id-reporting --resource-group rg-reporting --query principalId -o tsv
  {
    name = "reporting"
    entra_principal = {
      name      = "id-reporting"
      object_id = "33333333-3333-3333-3333-333333333333"
      type      = "service"
    }
  },
]
