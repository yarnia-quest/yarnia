# Yarnia (Flutter app)

The Yarnia client: a screen-off voice bedtime-story app that talks to the `api/` Worker
(conversational ElevenLabs agent + story/session endpoints).

## API base URL (per target)

The app reads its backend URL from a compile-time env var, `API_BASE`, via
`String.fromEnvironment` in `lib/main.dart`. No runtime detection — you pick it per target:

| Target | `API_BASE` | Why |
|---|---|---|
| Web (Chrome on the Mac) | `http://localhost:8787` (default) | browser shares the Mac's network |
| iOS Simulator | `http://localhost:8787` (default) | simulator shares the Mac's network |
| Physical iPhone | `https://yellowpine.taileb7778.ts.net` | a device can't reach the Mac's `localhost`; use the Tailscale URL (phone must be on the tailnet) |

Values live in `dart_defines/local.json` and `dart_defines/device.json`. Run with the matching one:

```sh
# web + simulator (localhost)
flutter run --dart-define-from-file=dart_defines/local.json -d chrome      # web
flutter run --dart-define-from-file=dart_defines/local.json -d <simulator> # iOS simulator

# physical iPhone (Tailscale)
flutter run --dart-define-from-file=dart_defines/device.json -d <device>

# one-off override (e.g. a LAN IP)
flutter run --dart-define=API_BASE=http://192.168.1.42:8787 -d <device>
```

In VS Code, pick **"Yarnia — local (web / simulator)"** or **"Yarnia — physical device (Tailscale)"**
from the Run menu (`.vscode/launch.json`) — selecting the target sets `API_BASE` for you.

The local targets need the `api/` Worker running: `cd ../../api && npm run dev` (serves `:8787`).
