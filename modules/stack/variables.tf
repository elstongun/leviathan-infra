variable "env" {
  description = "staging or production"
  type        = string
  validation {
    condition     = contains(["staging", "production"], var.env)
    error_message = "env must be staging or production."
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "domain" {
  description = "Root domain with an existing Route 53 hosted zone in this account, e.g. leviathan.dev (production) or staging.leviathan.dev."
  type        = string
}

variable "app_subdomain" {
  description = "Web app host: <app_subdomain>.<domain>"
  type        = string
  default     = "app"
}

variable "api_subdomain" {
  description = "Public query API and MCP host (levi-edge): <api_subdomain>.<domain>"
  type        = string
  default     = "api"
}

variable "control_subdomain" {
  description = "Control-plane host (levi-api; also receives Stripe webhooks): <control_subdomain>.<domain>"
  type        = string
  default     = "control"
}

variable "vpc_cidr" {
  type    = string
  default = "10.40.0.0/16"
}

variable "github_org" {
  description = "GitHub owner of the leviathan-platform and leviathan-web repositories."
  type        = string
}

variable "platform_repo" {
  type    = string
  default = "leviathan-platform"
}

variable "web_repo" {
  type    = string
  default = "leviathan-web"
}

variable "create_github_oidc_provider" {
  description = "Set false if this AWS account already has the token.actions.githubusercontent.com OIDC provider."
  type        = bool
  default     = true
}

variable "alert_email" {
  description = "Receives alarms, budget alerts and cost anomalies (confirm the SNS subscription email once)."
  type        = string
}

variable "monthly_budget_usd" {
  type    = number
  default = 400
}

variable "workos_client_id" {
  description = "WorkOS Client ID (not secret). The WorkOS API key goes in Secrets Manager."
  type        = string
}

variable "staff_org_id" {
  description = "Optional WorkOS organization whose members may open the admin panel (in addition to is_staff)."
  type        = string
  default     = ""
}

variable "calendly_url" {
  type    = string
  default = ""
}

variable "stripe_require_tos_consent" {
  description = "Ask for terms-of-service consent in Stripe Checkout (needs a terms URL set in the Stripe dashboard)."
  type        = bool
  default     = false
}

variable "enable_cdn" {
  description = <<-EOT
    Serve the web app through CloudFront (static assets cached at the edge).
    Off by default: uploads stream through the app to levi-api, and CloudFront
    gives an origin at most 60 s to answer, which very large uploads can exceed.
    Turn on once uploads go straight to S3 (presigned URLs).
  EOT
  type        = bool
  default     = false
}

variable "enable_cost_explorer" {
  description = "Let workers read AWS Cost Explorer for the admin panel's actual costs (enable Cost Explorer in the Billing console first)."
  type        = bool
  default     = true
}

# ---- Scale (plan section 7.5). Change these to move between stages. ----

variable "scale_stage" {
  description = "Shown on the admin Infrastructure page; informational."
  type        = number
  default     = 0
}

variable "cell_count" {
  type    = number
  default = 1
  validation {
    condition     = var.cell_count >= 1
    error_message = "At least one cell."
  }
}

variable "cell_instance_type" {
  type    = string
  default = "r8g.large"
}

variable "cell_volume_gb" {
  type    = number
  default = 100
}

variable "worker_count" {
  type    = number
  default = 1
}

variable "worker_instance_type" {
  type    = string
  default = "c8g.medium"
}

variable "worker_volume_gb" {
  description = "Root volume for workers: uploads (up to 2 GB) and index builds are staged here."
  type        = number
  default     = 60
}

variable "egress_ip_count" {
  description = "Elastic IPs customers allowlist. Keep one more than worker_count so the published list never changes."
  type        = number
  default     = 2
}

variable "rds_instance_class" {
  type    = string
  default = "db.t4g.medium"
}

variable "rds_multi_az" {
  type    = bool
  default = false
}

variable "rds_allocated_storage_gb" {
  type    = number
  default = 50
}

variable "web_desired_count" {
  type    = number
  default = 1
}

variable "api_desired_count" {
  type    = number
  default = 1
}

variable "edge_desired_count" {
  type    = number
  default = 1
}

variable "service_autoscaling_max" {
  type    = number
  default = 2
}

variable "enable_nat_gateway" {
  description = "Move services, cells and workers' outbound traffic behind a NAT gateway (workers keep their Elastic IPs)."
  type        = bool
  default     = false
}

variable "task_sizes" {
  description = "Fargate CPU units and memory (MiB) per service."
  type        = map(object({ cpu = number, memory = number }))
  default = {
    web  = { cpu = 512, memory = 1024 }
    api  = { cpu = 256, memory = 512 }
    edge = { cpu = 256, memory = 512 }
    ops  = { cpu = 256, memory = 512 }
  }
}
