# Same declarations in every environment; values live in terraform.tfvars.

variable "aws_account_id" {
  type = string
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "domain" {
  type = string
}

variable "github_org" {
  type = string
}

variable "create_github_oidc_provider" {
  type    = bool
  default = true
}

variable "alert_email" {
  type = string
}

variable "monthly_budget_usd" {
  type = number
}

variable "workos_client_id" {
  type = string
}

variable "staff_org_id" {
  type    = string
  default = ""
}

variable "calendly_url" {
  type    = string
  default = ""
}

variable "stripe_require_tos_consent" {
  type    = bool
  default = false
}

variable "enable_cdn" {
  type    = bool
  default = false
}

variable "enable_cost_explorer" {
  type    = bool
  default = true
}

variable "scale_stage" {
  type = number
}

variable "cell_count" {
  type = number
}

variable "cell_instance_type" {
  type = string
}

variable "cell_volume_gb" {
  type = number
}

variable "worker_count" {
  type = number
}

variable "worker_instance_type" {
  type = string
}

variable "egress_ip_count" {
  type = number
}

variable "rds_instance_class" {
  type = string
}

variable "rds_multi_az" {
  type = bool
}

variable "rds_allocated_storage_gb" {
  type = number
}

variable "web_desired_count" {
  type = number
}

variable "api_desired_count" {
  type = number
}

variable "edge_desired_count" {
  type = number
}

variable "service_autoscaling_max" {
  type = number
}

variable "enable_nat_gateway" {
  type = bool
}
