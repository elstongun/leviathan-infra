terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  name       = "levi-${var.env}"
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  azs        = slice(data.aws_availability_zones.available.names, 0, 2)

  app_host     = "${var.app_subdomain}.${var.domain}"
  api_host     = "${var.api_subdomain}.${var.domain}"
  control_host = "${var.control_subdomain}.${var.domain}"
  app_url      = "https://${local.app_host}"
  api_url      = "https://${local.api_host}"
  control_url  = "https://${local.control_host}"

  # Stage 0 runs everything with public addresses (no NAT); security groups
  # allow no inbound traffic except from the load balancer and each other.
  service_subnets  = var.enable_nat_gateway ? aws_subnet.private[*].id : aws_subnet.public[*].id
  assign_public_ip = !var.enable_nat_gateway

  blob_prefix = "blobs"
  storage_url = "s3://${aws_s3_bucket.blobs.bucket}/${local.blob_prefix}"
}

check "workers_fit_egress_ips" {
  assert {
    condition     = var.worker_count <= var.egress_ip_count
    error_message = "worker_count must not exceed egress_ip_count: every worker egresses from a published Elastic IP."
  }
}
