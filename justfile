# Yarnia dev commands
# Run: just <recipe>   (requires https://github.com/casey/just)

# Backend URL per environment lives in dart_defines/device.{dev,prod}.json
# (dev = http://localhost:8787, prod = https://api.yarnia.quest). Single source of truth.
DEVICE := "53111FDAP004SA"

# ── API ──────────────────────────────────────────────────────────────────────

# Start local API server (logs to stdout)
api:
    cd api && npm run dev

# Tail local API logs
logs:
    tail -f /tmp/yarnia-api-live.log

# Run API tests
test:
    cd api && npm test

# Deploy API to production (requires CLOUDFLARE_API_TOKEN + CLOUDFLARE_ACCOUNT_ID)
deploy-api:
    cd api && npm run typecheck && npm test && npx wrangler deploy

# Stream live logs from the deployed production Worker
tail-prod:
    cd api && npx wrangler tail --format pretty

# ── Flutter ───────────────────────────────────────────────────────────────────

# Run Flutter on device against LOCAL API (requires: just api + adb reverse)
flutter-local:
    adb reverse tcp:8787 tcp:8787
    cd app/flutter && ~/flutter/bin/flutter run -d {{DEVICE}} --dart-define-from-file=dart_defines/device.dev.json

# Run Flutter on device against PRODUCTION API
flutter-prod:
    cd app/flutter && ~/flutter/bin/flutter run -d {{DEVICE}} --dart-define-from-file=dart_defines/device.prod.json

# Build release APK against production API
flutter-release:
    cd app/flutter && ~/flutter/bin/flutter build apk --dart-define-from-file=dart_defines/device.prod.json

# ── Combined ─────────────────────────────────────────────────────────────────

# Start API + tunnel + Flutter against local (opens 2 bg processes, logs inline)
dev:
    #!/usr/bin/env bash
    set -e
    cd api && npm run dev >> /tmp/yarnia-api-live.log 2>&1 &
    echo "API started (logs: just logs)"
    sleep 4
    adb reverse tcp:8787 tcp:8787
    cd app/flutter && ~/flutter/bin/flutter run -d {{DEVICE}} --dart-define-from-file=dart_defines/device.dev.json
