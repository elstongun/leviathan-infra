terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # terraform init -backend-config="bucket=leviathan-tfstate-<staging account id>"
  backend "s3" {
    key          = "leviathan/staging.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region              = var.region
  allowed_account_ids = [var.aws_account_id]

  default_tags {
    tags = {
      Project     = "leviathan"
      Environment = "staging"
      ManagedBy   = "terraform"
    }
  }
}

module "stack" {
  source = "../../modules/stack"
  env    = "staging"
  region = var.region

  domain                      = var.domain
  github_org                  = var.github_org
  create_github_oidc_provider = var.create_github_oidc_provider
  alert_email                 = var.alert_email
  monthly_budget_usd          = var.monthly_budget_usd
  workos_client_id            = var.workos_client_id
  staff_org_id                = var.staff_org_id
  calendly_url                = var.calendly_url
  stripe_require_tos_consent  = var.stripe_require_tos_consent
  enable_cdn                  = var.enable_cdn
  enable_cost_explorer        = var.enable_cost_explorer

  scale_stage              = var.scale_stage
  cell_count               = var.cell_count
  cell_instance_type       = var.cell_instance_type
  cell_volume_gb           = var.cell_volume_gb
  worker_count             = var.worker_count
  worker_instance_type     = var.worker_instance_type
  egress_ip_count          = var.egress_ip_count
  rds_instance_class       = var.rds_instance_class
  rds_multi_az             = var.rds_multi_az
  rds_allocated_storage_gb = var.rds_allocated_storage_gb
  web_desired_count        = var.web_desired_count
  api_desired_count        = var.api_desired_count
  edge_desired_count       = var.edge_desired_count
  service_autoscaling_max  = var.service_autoscaling_max
  enable_nat_gateway       = var.enable_nat_gateway
}

output "stack" {
  value = module.stack
}
