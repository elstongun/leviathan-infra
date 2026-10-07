# Production. Not secret: no keys or passwords ever go in this file.
# Replace every REPLACE_ME before the first `terraform plan`.

aws_account_id   = "REPLACE_ME" # 12-digit production AWS account id
domain           = "REPLACE_ME" # e.g. leviathan.dev (Route 53 hosted zone in this account)
github_org       = "elstongun"
alert_email      = "REPLACE_ME" # alarms, budget and anomaly emails
workos_client_id = "REPLACE_ME" # WorkOS production Client ID (client_...)
calendly_url     = ""           # "Book a call" link, when you have it
staff_org_id     = ""           # optional WorkOS org for admin access

monthly_budget_usd = 400

# ---------------------------------------------------------------------------
# Scale (plan section 7.5). Each change is a reviewed `terraform plan`.
#
#                       Stage 0 (launch)   Stage 1 (redundant)   Stage 2+ (growth)
#   cell_count          1                  2                     +1 per ~25 GB indexed
#   cell_instance_type  r8g.large          r8g.large             r8g.xlarge+ when packing helps
#   cell_volume_gb      100                100                   2x the GB indexed on the cell
#   worker_count        1                  2                     2-4
#   egress_ip_count     2                  2                     2-4 (publish in advance)
#   rds_instance_class  db.t4g.medium      db.t4g.medium         db.m8g.large
#   rds_multi_az        false              true                  true
#   *_desired_count     1 / 1 / 1          2 / 2 / 2             2+ (auto scaling)
#   service_autoscaling_max  2             4                     10
#   enable_nat_gateway  false              false (true if a security review needs it)
#
# Savings Plans / Reserved Instances are bought in the AWS console once usage
# has been steady for two months; they are not Terraform-managed.
# ---------------------------------------------------------------------------

scale_stage = 0

cell_count         = 1
cell_instance_type = "r8g.large"
cell_volume_gb     = 100

worker_count         = 1
worker_instance_type = "c8g.medium"
egress_ip_count      = 2

rds_instance_class       = "db.t4g.medium"
rds_multi_az             = false
rds_allocated_storage_gb = 50

web_desired_count       = 1
api_desired_count       = 1
edge_desired_count      = 1
service_autoscaling_max = 2

enable_nat_gateway = false
enable_cdn         = false
