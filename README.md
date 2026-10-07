# leviathan-infra

Terraform for Leviathan Cloud on AWS (us-east-1), one AWS account per
environment.

```
bootstrap/          state bucket, once per account
modules/stack/      everything else: network, load balancer, Fargate services,
                    cells and workers on EC2, RDS, S3, KMS, secrets (empty),
                    DNS and certificates, alarms and budgets, GitHub OIDC, SES
envs/staging/       terraform.tfvars = staging settings
envs/production/    terraform.tfvars = production settings and scale knobs
scripts/            secrets and one-off operations (see docs)
docs/
  DEPLOYMENT.md     from empty accounts to running, plus scaling
  SECRETS.md        where every secret lives and how to set it safely
```

Start with [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md).

## Scaling

All capacity is in `envs/production/terraform.tfvars` (`cell_count`,
`cell_instance_type`, `worker_count`, `rds_multi_az`, desired counts, …).
The file's header lists the values for Stage 0, 1 and 2 from the plan. To
scale: edit, `terraform plan`, read it, `terraform apply`.

## Checks

```bash
terraform fmt -check -recursive
terraform -chdir=envs/staging init -backend=false && terraform -chdir=envs/staging validate
```

CI runs these on every push. Applies are always run by a person.
