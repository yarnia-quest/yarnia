#!/usr/bin/env bash
# Deploy the Yarnia signup Worker using values from the repo-root .env (gitignored).
# Usage: bash deploy.sh   (run from anywhere; paths are resolved relative to this script)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../../.env"

if [ ! -f "$ENV_FILE" ]; then
  echo "Missing $ENV_FILE — copy .env.example to .env and fill it in." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

: "${CLOUDFLARE_ACCOUNT_ID:?set CLOUDFLARE_ACCOUNT_ID in .env}"
: "${INSTANT_APP_ID:?set INSTANT_APP_ID in .env}"
: "${INSTANT_ADMIN_TOKEN:?set INSTANT_ADMIN_TOKEN in .env (InstantDB dashboard -> Admin SDK)}"

cd "$SCRIPT_DIR"

# wrangler auto-reads CLOUDFLARE_ACCOUNT_ID (and CLOUDFLARE_API_TOKEN if set, for non-interactive auth).
# Set/refresh the admin token secret, then deploy with the public app id as a var.
printf '%s' "$INSTANT_ADMIN_TOKEN" | npx wrangler secret put INSTANT_ADMIN_TOKEN
npx wrangler deploy --var INSTANT_APP_ID:"$INSTANT_APP_ID"
