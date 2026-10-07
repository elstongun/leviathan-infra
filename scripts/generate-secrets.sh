#!/usr/bin/env bash
# Fill the secrets we generate ourselves for one environment. Only empty
# secrets are filled, so rerunning never rotates anything by accident.
# Values are made locally with openssl, sent to Secrets Manager from a
# private temporary file, and never printed or passed as a command argument.
#
# Usage:
#   scripts/generate-secrets.sh staging
#   scripts/generate-secrets.sh production --rotate internal-token
set -euo pipefail

ENV="${1:-}"
[[ "$ENV" == "staging" || "$ENV" == "production" ]] || { echo "usage: $0 staging|production [--rotate NAME]" >&2; exit 2; }
ROTATE=""
if [[ "${2:-}" == "--rotate" ]]; then ROTATE="${3:?--rotate needs a secret name}"; fi
REGION="${AWS_REGION:-us-east-1}"

GENERATED=(db-app-password internal-token api-key-pepper workos-cookie-password)

has_value() {
  [[ "$(aws secretsmanager list-secret-version-ids --region "$REGION" --secret-id "levi/$ENV/$1" \
    --query "length(Versions[?contains(VersionStages, 'AWSCURRENT')])" --output text)" != "0" ]]
}

put_file() { # name, file
  aws secretsmanager put-secret-value --region "$REGION" --secret-id "levi/$ENV/$1" \
    --secret-string "file://$2" >/dev/null
}

TMP="$(mktemp)"
chmod 600 "$TMP"
trap 'rm -f "$TMP"' EXIT

for name in "${GENERATED[@]}"; do
  if [[ "$name" == "$ROTATE" ]]; then
    if [[ "$name" == "api-key-pepper" ]]; then
      echo "refusing to rotate api-key-pepper: every customer API key would stop working" >&2
      exit 1
    fi
  elif has_value "$name"; then
    echo "levi/$ENV/$name: already set"
    continue
  fi
  openssl rand -hex 32 | tr -d '\n' > "$TMP"
  put_file "$name" "$TMP"
  echo "levi/$ENV/$name: generated"
done

# Placeholder so tasks can start before `levi-ops stripe-setup` stores the real one.
if ! has_value stripe-webhook-secret; then
  printf 'whsec_pending_stripe_setup' > "$TMP"
  put_file stripe-webhook-secret "$TMP"
  echo "levi/$ENV/stripe-webhook-secret: placeholder (scripts/ops.sh $ENV stripe-setup replaces it)"
fi

if [[ "$ROTATE" == "db-app-password" ]]; then
  echo "next: scripts/ops.sh $ENV db-bootstrap, then redeploy every service"
elif [[ -n "$ROTATE" ]]; then
  echo "next: redeploy every service so they read the new value"
fi
