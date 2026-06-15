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

# Run Flutter on device against CORE (Tailscale, no adb reverse needed — Ollama on core)
flutter-core:
    cd app/flutter && flutter run --dart-define-from-file=dart_defines/core.json

# Build debug APK against core and install on both devices
build-core:
    cd app/flutter && flutter build apk --debug --dart-define-from-file=dart_defines/core.json
    adb -s LCL0218419004596 install -r app/flutter/build/app/outputs/flutter-apk/app-debug.apk &
    adb -s pixie:5555 install -r app/flutter/build/app/outputs/flutter-apk/app-debug.apk &
    wait && echo "Installed on both devices"

# Run Flutter on device against PRODUCTION API
flutter-prod:
    cd app/flutter && flutter run --dart-define-from-file=dart_defines/prod.json

# Build release APK against production API
flutter-release:
    cd app/flutter && flutter build apk --dart-define-from-file=dart_defines/prod.json

# Run the on-device voice spike (Speak/Listen test screens) instead of the app.
# Same package, different home screen via the TTS_SPIKE dart-define.
# Models live on-device under pocket-tts-* dirs; push with just pocket-push-models
# (or just pocket-spike-deploy for APK + models + launch).
flutter-spike:
    cd app/flutter && flutter run --dart-define-from-file=dart_defines/prod.json --dart-define=TTS_SPIKE=true

# ── Pocket TTS (on-device spike) ──────────────────────────────────────────────
# Composable pieces: export → push-models. Deploy adds debug APK install + launch.
# Debug APK is required so push_to_device.sh can run-as into the app files dir.

# Export all 4 spike languages (german, german_24l, french_24l, spanish)
pocket-export:
    cd tools/pocket-tts-export && ./export_all.sh

# Push exported models to a connected device (skips dirs not yet exported)
pocket-push-models pkg="quest.yarnia.yarnia":
    cd tools/pocket-tts-export && ./push_to_device.sh {{pkg}}

# Install debug APK only (builds if missing); use before pocket-push-models
pocket-install-debug pkg="quest.yarnia.yarnia":
    cd tools/pocket-tts-export && ./install_debug_apk.sh {{pkg}}

# Full spike deploy: debug APK + push models + launch app
pocket-spike-deploy pkg="quest.yarnia.yarnia":
    cd tools/pocket-tts-export && ./deploy_and_test.sh {{pkg}}

# ── Maestro E2E tests ────────────────────────────────────────────────────────
# Requires: device unlocked, screen on, Maestro in PATH (~/.local/maestro/bin/maestro)
# Keep screen on while plugged in (run once per device):
#   adb -s 53111FDAP004SA shell settings put global stay_on_while_plugged_in 3

# Full English conversation flow on USB device
maestro-en device="53111FDAP004SA":
    adb -s {{device}} shell input keyevent 224
    ~/.local/maestro/bin/maestro --device {{device}} test app/flutter/maestro/voice_conversation_en.yaml

# Full German conversation flow on USB device
maestro-de device="53111FDAP004SA":
    adb -s {{device}} shell input keyevent 224
    ~/.local/maestro/bin/maestro --device {{device}} test app/flutter/maestro/voice_conversation_de.yaml

# Run all Maestro flows
maestro-all device="53111FDAP004SA":
    adb -s {{device}} shell input keyevent 224
    ~/.local/maestro/bin/maestro --device {{device}} test app/flutter/maestro/

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
