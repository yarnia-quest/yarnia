# Yarnia (Flutter app)

The Yarnia client: a screen-off voice bedtime-story app that talks to the `api/` Worker
(conversational ElevenLabs agent + story/session endpoints).

## API base URL (per target)

The app reads its backend URL from a compile-time env var, `API_BASE`, via
`String.fromEnvironment` in `lib/main.dart`. No runtime detection. The default is the
deployed prod backend (`https://api.yarnia.quest`), so any build that forgets the flag
(web, device, release) connects to prod and never to localhost. Local dev against a local
`api/` Worker is an explicit opt-in.

| Target | `API_BASE` | Why |
|---|---|---|
| Physical device, web, any release build | `https://api.yarnia.quest` (default) | hits the deployed prod Worker; no dev server or tailnet needed |
| Web / simulator / device, local dev | `http://localhost:8787` (opt in via `local.json`) | shares the Mac's network (device via `adb reverse`); needs the local `api/` running |

Values live in `dart_defines/local.json` (localhost) and `dart_defines/prod.json`
(prod, same as the default). Run with the matching one:

```sh
# prod backend (default, no flag needed)
flutter run -d chrome
flutter build web

# local dev against a local api/ Worker (explicit opt-in)
flutter run --dart-define-from-file=dart_defines/local.json -d chrome      # web
flutter run --dart-define-from-file=dart_defines/local.json -d <simulator> # iOS simulator

# physical device, explicit prod (same as default)
flutter run --dart-define-from-file=dart_defines/prod.json -d <device>

# one-off override (e.g. a LAN IP)
flutter run --dart-define=API_BASE=http://192.168.1.42:8787 -d <device>
```

In VS Code, pick **"Yarnia: prod backend (device / web / release)"** (the default) or
**"Yarnia: local dev (web / simulator)"** from the Run menu (`.vscode/launch.json`);
selecting the target sets `API_BASE` for you.

The local-dev target needs the `api/` Worker running: `cd ../../api && npm run dev` (serves `:8787`).

## Web deploy (app.yarnia.quest)

`flutter build web` is served at **https://app.yarnia.quest** by an assets-only Cloudflare
Worker (`wrangler.toml` here — no Worker script; Cloudflare serves `build/web/` directly and
falls back to `index.html` for client-side routes via `not_found_handling`). The deploy holds
no secret: the backend URL is baked into the build at compile time, so the worker just serves
files and the app talks to `api.yarnia.quest`.

**Automatic (preferred):** any push to `main` touching `app/flutter/**` triggers
`.github/workflows/deploy-app.yml`, which builds with the prod backend
(`dart_defines/prod.json`) and deploys via `cloudflare/wrangler-action`. DNS + TLS for
`app.yarnia.quest` are provisioned by wrangler (`custom_domain` route) against the existing
`yarnia.quest` zone — nothing to set up by hand.

**Manual** (needs the Cloudflare deploy creds, which live in `api/.env`, never `app/.env` —
they are secrets and must not ship in the client bundle):

```sh
flutter build web --release --dart-define-from-file=dart_defines/prod.json
# load CLOUDFLARE_API_TOKEN + CLOUDFLARE_ACCOUNT_ID from api/.env, then:
npx wrangler deploy
```
