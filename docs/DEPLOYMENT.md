# Deploying Leviathan Cloud

From empty AWS accounts to a working staging and production. Do staging
first, end to end, then repeat for production. Allow about half a day for
the first environment, plus waiting time for AWS approvals.

What runs where (Stage 0, plan section 7.5):

| Piece | Runs on |
|---|---|
| `web` (Next.js), `levi-api`, `levi-edge` | ECS Fargate (ARM), behind one load balancer: `app.`, `control.`, `api.` hosts |
| `levi-cell` | 1 EC2 `r8g.large` with a 100 GB data volume (Auto Scaling group of 1) |
| `levi-sync` | 1 EC2 `c8g.medium` with a published Elastic IP (+1 spare IP) |
| Postgres | RDS `db.t4g.medium`, single-AZ, 7-day point-in-time recovery |
| Uploads, snapshots | S3 (versioned; 7-day recovery window) |
| Secrets | Secrets Manager (see [SECRETS.md](SECRETS.md)) |

## 0. One-time prerequisites

1. **Two AWS accounts** (staging, production) under AWS Organizations, with
   IAM Identity Center users and MFA. Configure CLI profiles:
   `aws configure sso` → profiles `levi-staging` and `levi-production`.
2. **Tools on your laptop:** AWS CLI v2, `jq`, and **Terraform 1.10 or
   newer** (state locking uses S3 natively). Your Homebrew Terraform is 1.4.3:
   ```bash
   brew uninstall terraform
   brew tap hashicorp/tap && brew install hashicorp/tap/terraform
   terraform version   # 1.10+
   ```
3. **Domain.** A Route 53 public hosted zone in each account: for example
   `leviathan.dev` in production and `staging.leviathan.dev` in staging (add
   the staging zone's four NS records to the production zone as an `NS`
   record named `staging`). If the domain is registered elsewhere, point its
   name servers at the production zone.
4. **GitHub.** Three repositories: `leviathan-platform`, `leviathan-web`,
   `leviathan-infra`. In the first two, create Environments named `staging`
   and `production` (Settings → Environments); on `production`, add yourself
   as a required reviewer.
5. **Accounts with vendors:** WorkOS (a Staging and a Production
   environment), Stripe (test mode now; live mode needs business and bank
   details).
6. In each AWS account: **enable Cost Explorer** (Billing console → Cost
   Explorer → Enable) so the admin panel can show actual costs.

## 1. State bucket (once per account)

```bash
export AWS_PROFILE=levi-staging && aws sso login
cd leviathan-infra/bootstrap
terraform init && terraform apply      # creates leviathan-tfstate-<account id>
```

## 2. Fill in the environment's settings

Edit `envs/staging/terraform.tfvars` and replace every `REPLACE_ME`: account
id, domain, GitHub owner, alert email, WorkOS **Client ID** (not the API
key). The scale settings are already at Stage 0. No secrets go in this file.

## 3. Create the infrastructure

```bash
cd ../envs/staging
terraform init -backend-config="bucket=leviathan-tfstate-$(aws sts get-caller-identity --query Account --output text)"
terraform plan -out tf.plan     # read it
terraform apply tf.plan         # ~15 minutes (database, certificate)
terraform output -json stack    # note deploy_role_arn, egress_ips, urls
```

The services will not be healthy yet: they have no images and no secrets.
That is expected.

Then confirm the SNS subscription email AWS sends to your alert address.

## 4. Secrets

Follow [SECRETS.md](SECRETS.md), "Setting them, step by step", steps 1–3:

```bash
cd leviathan-infra
scripts/generate-secrets.sh staging
scripts/put-secret.sh staging workos-api-key
scripts/put-secret.sh staging stripe-secret-key
scripts/secrets-status.sh staging      # all "set"
```

## 5. First deploy

1. In GitHub, for **both** `leviathan-platform` and `leviathan-web`, set
   Environment variables on `staging`: `AWS_DEPLOY_ROLE_ARN` (from the
   Terraform output) and `AWS_REGION` = `us-east-1`.
2. Push `leviathan-web` and `leviathan-platform` to `main`. Each push runs its
   **Deploy** workflow for staging.
3. The very first platform deploy builds and pushes the image, then stops at
   "Roll levi-api": the database role doesn't exist yet. Create it:
   ```bash
   scripts/ops.sh staging db-bootstrap
   ```
4. Re-run the failed platform workflow (Actions → Deploy → Re-run). It skips
   the build and rolls `levi-api` (which applies migrations), `levi-edge`,
   the cell and the worker.

## 6. Stripe

```bash
scripts/ops.sh staging stripe-setup \
  --webhook-base "$(terraform -chdir=envs/staging output -json stack | jq -r .control_url)" \
  --store-webhook-secret levi/staging/stripe-webhook-secret
```

This creates (or finds) the Starter product with the $10 base price
(charged at the start of each period), the `FOUNDING100` coupon (100% off
the base fee for 3 months, 50 redemptions) and the webhook endpoint; the
webhook's signing secret goes straight into Secrets Manager. There are no
metered prices: usage above the allowance is paid from prepaid credits,
bought as one-time Checkout payments, and requests are refused when the
allowance and credits run out. Re-run the platform **Deploy** workflow
so `levi-api` and the workers load it. Running it again later is safe.

In the Stripe dashboard: Settings → Billing → **Customer portal**: allow
updating payment methods, viewing invoices and cancelling. Set your public
business details and statement descriptor.

## 7. WorkOS (dashboard, about 15 minutes)

In the WorkOS environment matching this deployment (Staging / Production):

- **Redirects:** redirect URI `https://app.<domain>/auth/callback`; sign-in
  endpoint `https://app.<domain>/auth/sign-in`; sign-out redirect
  `https://app.<domain>/` (the landing page).
- **Authentication:** enable GitHub, Google and Microsoft OAuth. For
  production, use your own OAuth apps (GitHub OAuth App, Google Cloud OAuth
  client with a published consent screen, Microsoft Entra multi-tenant app);
  their client secrets are entered in WorkOS, never in our systems.
- **Branding:** upload the Leviathan logo, dark theme, accent `#2dd4bf`.

## 8. Make yourself an admin

Sign in once at `https://app.<domain>`, then:

```bash
scripts/ops.sh staging make-staff --email you@example.com
```

The **Admin** tab appears on your next page load.

## 9. Smoke test (staging)

- [ ] Sign in with GitHub, Google and Microsoft.
- [ ] New project → connect a Postgres you control (allowlist the two
      `egress_ips`) → every check turns green → pick a table → mapping
      preview shows cards.
- [ ] Review and build → Checkout with test card `4242 4242 4242 4242` and
      code `FOUNDING100` → build animation → live.
- [ ] Create an API key; `curl -H "Authorization: Bearer $KEY" https://api.<domain>/v1/describe`.
- [ ] Add the MCP server to Claude Code with the command on the key screen.
- [ ] Admin panel shows the team, revenue (test mode) and costs.
- [ ] Stripe dashboard → webhook endpoint shows successful deliveries.

## 10. Production

Repeat sections 1–9 with `AWS_PROFILE=levi-production`,
`envs/production`, live Stripe keys and the WorkOS Production environment.
Before launch also:

- [ ] **SES production access** (SES console → Account dashboard → Request
      production access; usually approved within a day).
- [ ] Stripe **live mode** activated (business details, bank account).
- [ ] Publish the production `egress_ips` in the docs; never release them
      (Terraform protects them with `prevent_destroy`).
- [ ] Deploy production by running each repo's **Deploy** workflow manually
      with `environment = production` (needs your approval).

## Day-to-day

- **Deploy:** merge to `main` → staging deploys automatically. Promote by
  running Deploy with `production` from the same commit.
- **Roll back:** run Deploy with `production` from the previous good commit
  (Actions → Deploy → Run workflow → choose the branch/tag). Images are
  immutable and kept (last 50).
- **One-off operations:** `scripts/ops.sh <env> <command>` (migrate,
  make-staff, move-instance, encrypt-check, stripe-setup).
- **Logs:** CloudWatch log groups `/levi/<env>/{web,api,edge,cell,sync,ops}`.
- **Shell on a cell or worker** (no SSH, no open ports): AWS console → EC2 →
  instance → Connect → Session Manager.

## Scaling (plan 7.5)

Every stage change is an edit to `envs/production/terraform.tfvars` followed
by `terraform plan` and `terraform apply`. The admin panel's Infrastructure
page shows which trigger is amber or red and which variable to change.

- **Add a cell:** `cell_count = 2`. The new cell boots, registers itself and
  receives new projects. Move a heavy project onto it with
  `scripts/ops.sh production move-instance --instance <id> --to-cell cell-1`.
- **Stage 1 (redundant, ~70 paying teams):** `cell_count = 2`,
  `rds_multi_az = true`, `web/api/edge_desired_count = 2`,
  `worker_count = 2`, `service_autoscaling_max = 4`, `scale_stage = 1`.
  The second worker uses the spare Elastic IP customers already allowlisted.
- **Bigger cells:** change `cell_instance_type`; each cell is replaced one at
  a time and restores its indexes from its kept data volume (queries to that
  cell fail for a few minutes; do it off-peak).
- **More egress IPs:** raise `egress_ip_count`, publish the new address, and
  give customers a few weeks before `worker_count` uses it.

## Costs to expect

About $320/month for production at Stage 0 and about $190/month for staging
(on demand, us-east-1). AWS Budgets emails you at 80% of
`monthly_budget_usd` and when the month is forecast to exceed it.
