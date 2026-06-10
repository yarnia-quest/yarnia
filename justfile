# Yarnia dev commands
# Run: just <recipe>   (requires https://github.com/casey/just)

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
    cd app/flutter && flutter run --dart-define-from-file=dart_defines/local.json

# Run Flutter on device against PRODUCTION API
flutter-prod:
    cd app/flutter && flutter run --dart-define-from-file=dart_defines/prod.json

# Build release APK against production API
flutter-release:
    cd app/flutter && flutter build apk --dart-define-from-file=dart_defines/prod.json

# Run the on-device voice spike (Speak/Listen test screens) instead of the app.
# Same package, different home screen via the TTS_SPIKE dart-define. Models are
# pushed separately via adb run-as (see lib/screens/tts_spike_screen.dart).
flutter-spike:
    cd app/flutter && flutter run --dart-define-from-file=dart_defines/prod.json --dart-define=TTS_SPIKE=true

# ── Flutter web (app.yarnia.quest) ────────────────────────────────────────────

# Run Flutter web (Chrome) against LOCAL API (requires: just api)
flutter-web-local:
    cd app/flutter && flutter run -d chrome --dart-define-from-file=dart_defines/local.json

# Run Flutter web (Chrome) against PRODUCTION API
flutter-web-prod:
    cd app/flutter && flutter run -d chrome --dart-define-from-file=dart_defines/prod.json

# Build web client (prod API) + deploy to app.yarnia.quest (creds auto-loaded from api/.env)
deploy-app:
    #!/usr/bin/env bash
    set -euo pipefail
    # Cloudflare deploy creds live in api/.env (app/.env is public-only). Load just the
    # two CLOUDFLARE_* vars so wrangler, run from app/flutter (which has no creds), can auth.
    while IFS= read -r line; do export "$line"; done < <(grep -E '^CLOUDFLARE_(API_TOKEN|ACCOUNT_ID)=' api/.env)
    cd app/flutter
    flutter build web --release --dart-define-from-file=dart_defines/prod.json
    npx wrangler deploy

# ── Combined ─────────────────────────────────────────────────────────────────

# Start API + tunnel + Flutter against local (opens 2 bg processes, logs inline)
dev:
    #!/usr/bin/env bash
    set -e
    cd api && npm run dev >> /tmp/yarnia-api-live.log 2>&1 &
    echo "API started (logs: just logs)"
    sleep 4
    adb reverse tcp:8787 tcp:8787
    cd app/flutter && flutter run --dart-define-from-file=dart_defines/local.json
