# Yarnia

> Open the app. Screen goes off. It talks to you.

A screen-off voice companion for bedtime. A parent opens Yarnia at 8pm, the screen
dims, and a voice tells their child a personalized story that remembers them across
nights. No feed. No scroll. Just a voice in the dark.

**Live:**
- Landing page: https://yarnia.quest
- App (Flutter web): https://app.yarnia.quest
- API: https://api.yarnia.quest

## What it does

You open Yarnia. The screen turns off. A voice greets the child by name (or asks for
it the first time), then co-creates a story with them and narrates it. It offers:

- **Personalized bedtime stories** with remembered characters, themes, and fears to avoid
- **Conversational co-creation** ("an owl and a cat lost in Hamburg?") before it generates
- **A content-safety guardrail** baked into every prompt (age-appropriate, avoids the
  child's named fears)
- **A memory layer** so night two knows what worked on night one
- **A shareable result** ("Send to grandma") and replayable narration

It remembers. It adapts. It knows when to shut up.

## What works today (June 6, 2026 build)

The end-to-end demo arc runs against the live backend:

- [x] Voice greeting on open (time-aware, name-aware) via the ElevenLabs agent
- [x] Conversational intent + co-creation loop (greeting, onboarding, co-creation screens)
- [x] Story generation (Qwen) + ElevenLabs narration, returned to the app as audio
- [x] Session + child profile saved to InstantDB (private, worker-only)
- [x] Per-child memory injected into the next session's prompt
- [x] Shareable link and in-app replay of past stories
- [x] 85 backend tests (Vitest) and CI deploy for api, app, marketing, and schema

Stretch (not in the core demo): ambient soundscapes, public publishing.

## The pitch

Every consumer app in 2026 optimizes for your attention. Yarnia optimizes for your
presence. The phone becomes a voice in the dark instead of a screen stealing the night.

- **The buyer:** a parent at 8pm, kid in bed, trying to get them to sleep. That person
  exists every single night.
- **The price:** EUR 8/month. Below the "do I really need this" threshold (Spotify EUR 10,
  Calm EUR 8).
- **The gap:** Calm makes you stare at it, Spotify Sleep is not personalized, ChatGPT is a
  general assistant that needs typing. None combine screen-off + personalized + a ritual.
- **The moat:** the memory layer. After three nights it knows Lisa likes dragons, gets
  scared of thunder, and fell asleep faster with a cat in the story. Switching means
  starting that over.

## Architecture

Three domains, one repo:

| Domain | Serves | Code | Secrets |
| --- | --- | --- | --- |
| `yarnia.quest` | Marketing landing + waitlist | `marketing/` (CF Worker, static assets) | none (signup is a client-side InstantDB create) |
| `app.yarnia.quest` | The Flutter web client | `app/flutter/` (`flutter build web`) | none |
| `api.yarnia.quest` | Product backend | `api/` (Hono on CF Workers) | all server-side only |

Request flow for a story: the Flutter client calls `POST /story` -> the Worker loads the
child's profile and history from InstantDB -> builds a safety + memory prompt
(`api/src/prompt.ts`) -> generates text with Qwen -> narrates with ElevenLabs -> returns
the text and audio, and persists the session back to InstantDB.

Backend endpoints (`api/src/index.ts`):

- `POST /story` - generate + narrate a story for a child
- `POST /child` - onboarding: create a child profile, return its id
- `GET  /agent/session` - dynamic variables for the ElevenLabs conversational agent
  (works anonymously before a child is known)
- `POST /agent/webhook` - persist what the agent produced
- `GET  /child/:childId/sessions` - a child's story history
- `GET  /audio-url/:key` - signed URL for stored narration (replay)

## Stack

- **Frontend:** Flutter (Dart) - one codebase for iOS, Android, and web (`app/flutter/`)
- **Backend:** Hono on Cloudflare Workers (`api/`)
- **DB / auth / realtime / storage:** InstantDB
- **Voice / TTS:** ElevenLabs (conversational agent + single-shot narration)
- **Story generation:** Qwen via DashScope (OpenAI-compatible, `qwen3.7-max`)

## Run it locally

Prereqs: Node 24 (LTS) and the Flutter SDK.

**Backend (`api/`):**

```bash
cd api
npm install
cp .env.example .env   # fill in INSTANT_*, QWEN_API_KEY, ELEVENLABS_* (see api/.env.example)
npm run dev            # local Worker on :8787
npm test               # Vitest (in-process, mocks Qwen/ElevenLabs, costs nothing)
npm run typecheck
```

**Frontend (`app/flutter/`):** config is passed at build time with `--dart-define`
(see `app/flutter/dart_defines/`), not a `.env` file.

```bash
cd app/flutter
flutter pub get
flutter run -d chrome                                                # prod backend (default)
flutter run --dart-define-from-file=dart_defines/local.json -d chrome # local api on :8787
flutter build web --release --dart-define-from-file=dart_defines/prod.json
```

**Marketing (`marketing/`):** `cd marketing && npm install && npx wrangler dev`.

More detail and worktree/CI notes are in `CLAUDE.md` and each subproject's README.

## Tests and CI

- `api/` has 85 passing unit tests plus integration tests (Vitest). Run `npm test` in `api/`.
- GitHub Actions deploy on push by path: `deploy-api.yml`, `deploy-app.yml`, `deploy.yml`
  (marketing), and `push-schema.yml` (InstantDB schema + permissions as code).
- The demo-critical logic (content-safety guardrail + per-child memory in
  `api/src/prompt.ts`) is pure and fully unit-tested.

## Security and data

- **Trust-boundary split for config:** all secrets live in `api/.env` (server-side only:
  InstantDB admin token, Qwen and ElevenLabs keys, Cloudflare creds). The client only ever
  sees public values (`app/.env.example`). No secret is committed; `.env` and `.dev.vars`
  are gitignored, only `.env.example` templates are tracked.
- **Private child data:** InstantDB permissions (`instant/instant.perms.ts`) give the client
  no read or write access to `children` or `sessions`; only the backend Worker (admin token)
  touches them. The waitlist `signups` entity is create-only for guests.
- **Content safety:** every story prompt carries an age-appropriate guardrail and avoids the
  child's named fears (`api/src/prompt.ts`).

## Repo layout

- `app/flutter/` - the Flutter client (iOS, Android, web)
- `api/` - Hono backend Worker (story gen, TTS, InstantDB, safety guardrail)
- `marketing/` - landing page + waitlist (static assets Worker)
- `instant/` - InstantDB schema + permissions as code
- `infra/` - config, secrets, and CI notes
- `ideation/` - strategy and pitch docs (not code)

## License

Proprietary. See [LICENSE](LICENSE). All rights reserved by the authors.

## Team

- Burhan Yasar
- Cansin Yildiz

---

*Built at AI BEAVERS x Mollie Founder Hackathon, Hamburg, June 6 2026*
