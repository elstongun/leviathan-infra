output "app_url" {
  value = local.app_url
}

output "api_url" {
  value = local.api_url
}

output "control_url" {
  description = "levi-api; pass to `levi-ops stripe-setup --webhook-base`"
  value       = local.control_url
}

output "egress_ips" {
  description = "Publish these; customers allowlist them."
  value       = aws_eip.egress[*].public_ip
}

output "deploy_role_arn" {
  description = "Set as AWS_DEPLOY_ROLE_ARN in the GitHub Environment of the same name."
  value       = aws_iam_role.deploy.arn
}

output "ecr_repositories" {
  value = { for k, r in aws_ecr_repository.this : k => r.repository_url }
}

output "cluster" {
  value = aws_ecs_cluster.main.name
}

output "secret_names" {
  description = "Fill these with scripts/put-secret.sh or scripts/generate-secrets.sh."
  value       = [for s in aws_secretsmanager_secret.this : s.name]
}

output "db_master_secret_arn" {
  description = "RDS-managed master credentials; only levi-ops db-bootstrap uses them."
  value       = local.db_master_secret_arn
}

output "ops_task" {
  description = "Run one-off levi-ops commands with scripts/ops.sh."
  value = {
    family           = aws_ecs_task_definition.this["ops"].family
    subnets          = local.service_subnets
    security_group   = aws_security_group.this["ops"].id
    assign_public_ip = local.assign_public_ip
  }
}

output "blob_bucket" {
  value = aws_s3_bucket.blobs.bucket
}
