#!/usr/bin/env bash
# Show which secrets have a value, without ever reading the values.
# Usage: scripts/secrets-status.sh staging|production
set -euo pipefail

ENV="${1:-}"
[[ "$ENV" == "staging" || "$ENV" == "production" ]] || { echo "usage: $0 staging|production" >&2; exit 2; }
REGION="${AWS_REGION:-us-east-1}"

missing=0
for name in db-app-password internal-token api-key-pepper workos-cookie-password workos-api-key stripe-secret-key stripe-webhook-secret; do
  count="$(aws secretsmanager list-secret-version-ids --region "$REGION" --secret-id "levi/$ENV/$name" \
    --query "length(Versions[?contains(VersionStages, 'AWSCURRENT')])" --output text 2>/dev/null || echo "missing")"
  case "$count" in
    0) echo "EMPTY    levi/$ENV/$name"; missing=1 ;;
    missing) echo "MISSING  levi/$ENV/$name (run terraform apply first)"; missing=1 ;;
    *) echo "set      levi/$ENV/$name" ;;
  esac
done
exit "$missing"
