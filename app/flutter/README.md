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
| Web / simulator / device, local dev | `http://localhost:8787` (opt in via `device.dev.json`) | shares the Mac's network (device via `adb reverse`); needs the local `api/` running |

Values live in `dart_defines/device.dev.json` (localhost) and `dart_defines/device.prod.json`
(prod, same as the default). Run with the matching one:

```sh
# prod backend (default, no flag needed)
flutter run -d chrome
flutter build web

# local dev against a local api/ Worker (explicit opt-in)
flutter run --dart-define-from-file=dart_defines/device.dev.json -d chrome      # web
flutter run --dart-define-from-file=dart_defines/device.dev.json -d <simulator> # iOS simulator

# physical device, explicit prod (same as default)
flutter run --dart-define-from-file=dart_defines/device.prod.json -d <device>

# one-off override (e.g. a LAN IP)
flutter run --dart-define=API_BASE=http://192.168.1.42:8787 -d <device>
```

In VS Code, pick **"Yarnia: prod backend (device / web / release)"** (the default) or
**"Yarnia: local dev (web / simulator)"** from the Run menu (`.vscode/launch.json`);
selecting the target sets `API_BASE` for you.

The local-dev target needs the `api/` Worker running: `cd ../../api && npm run dev` (serves `:8787`).
