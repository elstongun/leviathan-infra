# Secrets: where each one lives and how to set it safely

Short version: **every secret lives in AWS Secrets Manager, in the AWS
account of its environment, and nowhere else.** You set them with two
scripts in this repo that read the value with hidden input and send it
straight to AWS. Terraform creates the empty slots but never sees a value,
so nothing secret ends up in git, in Terraform state, in GitHub, in your
shell history, or in a chat window.

## The rules

1. **Never paste a secret into chat, a ticket, a commit, a `.tfvars` file,
   or a GitHub secret.** If one leaks, rotate it (see the end of this page).
2. **One AWS account per environment.** Staging secrets (Stripe test mode,
   WorkOS staging) live only in the staging account; production secrets
   (Stripe live mode, WorkOS production) only in the production account. The
   Terraform provider refuses to run against the wrong account
   (`allowed_account_ids`), and the services refuse a live Stripe key outside
   production and a test key in production.
3. **Least privilege.** Each service can read only the secrets in its row
   below; nothing else in AWS can read them (including CI).
4. **Laptops get test-mode keys only**, in git-ignored `.env` files, and only
   if you want to test real sign-in or checkout locally. The demo UI needs no
   secrets at all.

## The secrets

All names are `levi/<env>/<name>`, for example `levi/production/stripe-secret-key`.

| Name | What it is | Where it comes from | How to set it | Read by |
|---|---|---|---|---|
| `db-app-password` | Password of the `levi_app` database role the services log in as | Generated | `scripts/generate-secrets.sh <env>` | api, edge, ops, cells, workers |
| `internal-token` | Bearer token on the private calls from edge, api, workers and ops to the cells | Generated | `scripts/generate-secrets.sh <env>` | api, edge, ops, cells, workers |
| `api-key-pepper` | Server-side pepper mixed into customer API-key hashes | Generated | `scripts/generate-secrets.sh <env>` | api, edge |
| `workos-cookie-password` | Encrypts the browser session cookie | Generated | `scripts/generate-secrets.sh <env>` | web |
| `workos-api-key` | WorkOS API key (`sk_…`) | WorkOS dashboard → the matching environment (Staging or Production) → API Keys | `scripts/put-secret.sh <env> workos-api-key` | api, web |
| `stripe-secret-key` | Stripe **restricted** key (`rk_test_…` in staging, `rk_live_…` in production) | Stripe dashboard → Developers → API keys → Create restricted key (permissions below) | `scripts/put-secret.sh <env> stripe-secret-key` | api, ops, workers |
| `stripe-webhook-secret` | Signing secret (`whsec_…`) that proves webhooks really came from Stripe | Created by `levi-ops stripe-setup` | Stored automatically by `scripts/ops.sh <env> stripe-setup … --store-webhook-secret levi/<env>/stripe-webhook-secret` | api, ops, workers |
| RDS master credentials (`rds!db-…`) | The database administrator login | Created, stored and rotated by RDS itself | Nothing to do | only `levi-ops db-bootstrap` |

What is **not** secret, and where it goes instead:

| Value | Where |
|---|---|
| WorkOS Client ID (`client_…`) | `workos_client_id` in `envs/<env>/terraform.tfvars` |
| Stripe **publishable** key (`pk_…`) | Not used. Checkout and the billing portal are created on the server and the browser is simply redirected, so the app never needs it. Keep it in your password manager. |
| AWS account ids, domain, alert email, Calendly link | `envs/<env>/terraform.tfvars` |
| The deploy role ARN | GitHub → each repo → Settings → Environments → `staging`/`production` → variable `AWS_DEPLOY_ROLE_ARN`. It is an identifier, not a credential: only GitHub workflows running in that environment can use it. |

KMS keys are not secrets you handle: the key that encrypts customers'
database credentials never leaves AWS KMS. `levi-api` may only encrypt with
it; only the sync workers (and the ops task) may decrypt.

## Setting them, step by step

You need the AWS CLI signed in to the right account, for example
`aws sso login --profile levi-staging` then `export AWS_PROFILE=levi-staging`.

```bash
cd leviathan-infra

# 1. After `terraform apply` has created the empty secrets:
scripts/generate-secrets.sh staging          # fills the 4 generated ones + a webhook placeholder

# 2. The two you get from vendors (hidden prompt; checks the key type):
scripts/put-secret.sh staging workos-api-key
scripts/put-secret.sh staging stripe-secret-key

# 3. Check (prints set/EMPTY, never the values):
scripts/secrets-status.sh staging

# 4. After the first deploy: create the Stripe catalog and webhook; the
#    signing secret goes straight into Secrets Manager.
scripts/ops.sh staging stripe-setup \
  --webhook-base https://control.<your staging domain> \
  --store-webhook-secret levi/staging/stripe-webhook-secret
```

Then re-run the **Deploy** workflow in `leviathan-platform` and
`leviathan-web` so every service starts with the new values (services read
secrets when they start).

Repeat with `production` (and live keys) in the production account.

### Why the scripts and not the AWS console?

Both work. The console is fine for a one-off. The scripts additionally
refuse the classic mistakes (a live Stripe key in staging, a test key in
production, overwriting the pepper), keep values out of `ps` and your shell
history, and never print anything.

## The Stripe restricted key

Create it in the Stripe dashboard (Developers → API keys → **Create
restricted key**), once in test mode for staging and once in live mode for
production. Give it **Write** on:

- Customers
- Checkout Sessions
- Customer portal (billing portal sessions)
- Subscriptions
- Billing meter events (usage reporting) and Billing meters
- Products, Prices and Coupons (used only by `stripe-setup`)
- Webhook endpoints (used only by `stripe-setup`)

and **Read** on Payment Methods (to fingerprint the card for the
one-founding-offer-per-card rule). Everything else: **None**. If a call is
ever refused, the error names the missing permission; add only that one.
(The exact labels in the dashboard can differ slightly from this list.)

## How the secrets reach the code

- **Fargate services (web, levi-api, levi-edge, levi-ops):** the task
  definition lists the secret ARNs; ECS fetches the values when a task
  starts and passes them as environment variables. Each service has its own
  execution role that may read only its own secrets.
- **EC2 cells and workers:** `/opt/levi/deploy.sh` (written by the boot
  script) fetches the values with the instance role and writes them to
  `/opt/levi/env`, readable by root only, then starts the container. It runs
  at boot and on every deploy.
- **The database password** reaches services as `PGPASSWORD`; the master
  password is only ever injected into the one-off `db-bootstrap` task.

## Rotation

| Secret | How | Impact |
|---|---|---|
| `stripe-secret-key` | Create a new restricted key, `put-secret.sh`, re-run both Deploy workflows, then delete the old key in Stripe | None |
| `stripe-webhook-secret` | Stripe dashboard → webhook endpoint → Roll secret, `put-secret.sh`, redeploy | Webhooks fail for the minutes between rolling and redeploying; Stripe retries them |
| `workos-api-key` | New key in WorkOS, `put-secret.sh`, redeploy, revoke the old one | None |
| `workos-cookie-password` | `generate-secrets.sh <env> --rotate workos-cookie-password`, redeploy web | Everyone is signed out once |
| `internal-token` | `generate-secrets.sh <env> --rotate internal-token`, redeploy everything | Queries fail for the minute while old and new services overlap |
| `db-app-password` | `generate-secrets.sh <env> --rotate db-app-password`, `ops.sh <env> db-bootstrap`, redeploy everything | Brief errors during the redeploy |
| `api-key-pepper` | Don't. Changing it invalidates every customer's API key; the script refuses | — |
| RDS master | Automatic (RDS) | None |

## If a secret leaks

1. Rotate it immediately (table above). For Stripe or WorkOS keys, revoke the
   old key in their dashboard as soon as the new one is deployed.
2. Check CloudTrail (`GetSecretValue` events) and the vendor's logs for use
   you don't recognise.
3. If it was ever committed to git, rotating is the fix; rewriting history is
   not enough because clones and caches keep it.
