# Staging: same shape as production, smaller and cheaper (about $190/month
# on demand; scale cell/worker counts to 0 is not supported, destroy instead).
# Stripe TEST mode and WorkOS staging environment. No secrets in this file.

aws_account_id   = "REPLACE_ME" # 12-digit staging AWS account id
domain           = "REPLACE_ME" # e.g. staging.leviathan.dev (hosted zone in the staging account)
github_org       = "elstongun"
alert_email      = "REPLACE_ME"
workos_client_id = "REPLACE_ME" # WorkOS staging Client ID
calendly_url     = ""
staff_org_id     = ""

monthly_budget_usd = 150

scale_stage = 0

cell_count         = 1
cell_instance_type = "r8g.medium"
cell_volume_gb     = 30

worker_count         = 1
worker_instance_type = "c8g.medium"
egress_ip_count      = 2

rds_instance_class       = "db.t4g.small"
rds_multi_az             = false
rds_allocated_storage_gb = 20

web_desired_count       = 1
api_desired_count       = 1
edge_desired_count      = 1
service_autoscaling_max = 2

enable_nat_gateway = false
enable_cdn         = false
