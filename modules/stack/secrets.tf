# Secrets Manager entries are created EMPTY. Values are written by hand or by
# leviathan-infra/scripts/generate-secrets.sh, never by Terraform, so no
# secret value is ever stored in Terraform state or in git.
# See docs/SECRETS.md in this repository for each one.

locals {
  secret_catalog = {
    "db-app-password"        = "Password of the levi_app database role (generated)"
    "internal-token"         = "Bearer token between edge/api/workers and cells (generated)"
    "api-key-pepper"         = "Server-side pepper for API-key hashes (generated; never rotate casually)"
    "workos-api-key"         = "WorkOS API key (sk_...), from the WorkOS dashboard"
    "workos-cookie-password" = "AuthKit session cookie password, 32+ characters (generated)"
    "stripe-secret-key"      = "Stripe restricted key (rk_...) or secret key; test mode in staging, live in production"
    "stripe-webhook-secret"  = "Stripe webhook signing secret (whsec_...), printed by levi-ops stripe-setup"
  }
}

resource "aws_secretsmanager_secret" "this" {
  for_each                = local.secret_catalog
  name                    = "levi/${var.env}/${each.key}"
  description             = each.value
  recovery_window_in_days = 7
}

locals {
  secret_arn = { for k, s in aws_secretsmanager_secret.this : k => s.arn }
  # RDS-managed master secret: JSON with username and password keys.
  db_master_secret_arn = aws_db_instance.main.master_user_secret[0].secret_arn
}
