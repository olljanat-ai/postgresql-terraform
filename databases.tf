################################################################################
# Databases and their owners
#
# These are objects inside PostgreSQL rather than Azure resources, so no Azure
# Verified Module covers them and they are managed over the wire protocol.
# Creating a database through Azure Resource Manager, which is what the AVM
# PostgreSQL module does, always leaves it owned by the administrator.
################################################################################

resource "random_password" "owner" {
  for_each = local.databases

  length           = 32
  special          = true
  override_special = "!#%&*()-_=+[]<>:?"
}

resource "postgresql_role" "owner" {
  for_each = local.databases

  name     = local.owner_role_names[each.key]
  login    = true
  password = random_password.owner[each.key].result

  # The module owns both the server and its firewall rules, so waiting for it
  # covers the network path this provider needs.
  depends_on = [module.postgresql_server]
}

# The administrator is not a superuser on Azure, so it can only create a
# database owned by another role, and later revoke privileges on it, while it is
# a member of that role. The membership is granted before the database is
# created, which also makes the provider skip the temporary grant it would
# otherwise revoke right after the database is created.
resource "postgresql_grant_role" "owner_to_administrator" {
  for_each = local.databases

  role       = var.administrator_login
  grant_role = postgresql_role.owner[each.key].name

  # The administrator created the role, so it is already its grantor and cannot
  # be granted the admin option back.
  with_admin_option = false
}

resource "postgresql_database" "this" {
  for_each = local.databases

  depends_on = [postgresql_grant_role.owner_to_administrator]

  name       = each.key
  owner      = postgresql_role.owner[each.key].name
  template   = "template0"
  encoding   = each.value.charset
  lc_collate = each.value.collation
  lc_ctype   = each.value.collation
}

################################################################################
# Hardening
################################################################################

# Without this every role, including the owners of the other databases, can
# connect to the database through the PUBLIC role.
resource "postgresql_grant" "revoke_public_connect" {
  for_each = var.revoke_public_connect ? local.databases : {}

  database    = each.key
  role        = "public"
  object_type = "database"
  privileges  = []

  depends_on = [
    postgresql_database.this,
    postgresql_grant_role.owner_to_administrator,
  ]
}
