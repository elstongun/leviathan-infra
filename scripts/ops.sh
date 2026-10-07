#!/usr/bin/env bash
# Run one levi-ops command as a one-off Fargate task inside the VPC (it can
# reach the private database), wait for it, and print its output.
# Needs: aws CLI, jq, and `terraform init` done in envs/<env>.
#
# Usage:
#   scripts/ops.sh staging db-bootstrap
#   scripts/ops.sh staging migrate
#   scripts/ops.sh staging stripe-setup --webhook-base https://control.example.com \
#       --store-webhook-secret levi/staging/stripe-webhook-secret
#   scripts/ops.sh production make-staff --email you@example.com
set -euo pipefail

ENV="${1:-}"
[[ "$ENV" == "staging" || "$ENV" == "production" ]] && [[ $# -ge 2 ]] \
  || { echo "usage: $0 staging|production COMMAND [ARGS...]" >&2; exit 2; }
shift
REGION="${AWS_REGION:-us-east-1}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

STACK="$(terraform -chdir="$ROOT/envs/$ENV" output -json stack)"
CLUSTER="$(jq -r .cluster <<<"$STACK")"
FAMILY="$(jq -r .ops_task.family <<<"$STACK")"
NETWORK="$(jq -c '{awsvpcConfiguration: {
  subnets: .ops_task.subnets,
  securityGroups: [.ops_task.security_group],
  assignPublicIp: (if .ops_task.assign_public_ip then "ENABLED" else "DISABLED" end)}}' <<<"$STACK")"
OVERRIDES="$(jq -nc '{containerOverrides: [{name: "ops", command: (["levi-ops"] + $ARGS.positional)}]}' --args "$@")"

TASK_ARN="$(aws ecs run-task --region "$REGION" --cluster "$CLUSTER" --task-definition "$FAMILY" \
  --launch-type FARGATE --network-configuration "$NETWORK" --overrides "$OVERRIDES" \
  --query 'tasks[0].taskArn' --output text)"
TASK_ID="${TASK_ARN##*/}"
echo "started $TASK_ID: levi-ops $*"

aws ecs wait tasks-stopped --region "$REGION" --cluster "$CLUSTER" --tasks "$TASK_ARN"
aws logs get-log-events --region "$REGION" --log-group-name "/levi/$ENV/ops" \
  --log-stream-name "ops/ops/$TASK_ID" --start-from-head --query 'events[].message' --output text | tr '\t' '\n' || true

CODE="$(aws ecs describe-tasks --region "$REGION" --cluster "$CLUSTER" --tasks "$TASK_ARN" \
  --query 'tasks[0].containers[0].exitCode' --output text)"
REASON="$(aws ecs describe-tasks --region "$REGION" --cluster "$CLUSTER" --tasks "$TASK_ARN" \
  --query 'tasks[0].stoppedReason' --output text)"
if [[ "$CODE" != "0" ]]; then
  echo "levi-ops exited with $CODE ($REASON)" >&2
  exit 1
fi
