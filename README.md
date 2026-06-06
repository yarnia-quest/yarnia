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
- **A content-safety guardrail** baked into every prompt AND an output moderation pass
  (age-appropriate, avoids the child's named fears, never narrates unsafe text)
- **A memory layer** so night two knows what worked on night one
- **Multiple children per device** with a profile picker (a household with siblings)
- **A shareable result** ("Send to grandma") via an unguessable link, and replayable narration
- **An EUR 8/month subscription** with Mollie hosted checkout

It remembers. It adapts. It knows when to shut up.

## What works today (June 6, 2026 build)

The end-to-end demo arc runs against the live backend:

- [x] Voice greeting on open (time-aware, name-aware) via the ElevenLabs agent
- [x] Conversational intent + co-creation loop (greeting, onboarding, co-creation screens)
- [x] Story generation (Qwen) + ElevenLabs narration, returned to the app as audio
- [x] Session + child profile saved to InstantDB (private, worker-only)
- [x] Per-child memory injected into the next session's prompt
- [x] Multiple child profiles per device, with a profile switcher
- [x] Per-child auth tokens (X-Child-Token) so a profile is bound to its device
- [x] Shareable link (unguessable token) and in-app replay of past stories
- [x] EUR 8/month subscription via Mollie hosted checkout (POST /checkout)
- [x] Rate limiting, structured logging, and optional error/analytics webhooks
- [x] 129 backend tests (Vitest) and CI deploy for api, app, marketing, and schema

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

- `POST /story` - generate + narrate a story for a child (requires the child token)
- `POST /child` - onboarding: create a child profile, return its id + a per-child auth token
- `GET  /agent/session` - dynamic variables for the ElevenLabs conversational agent
  (works anonymously before a child is known; a named child requires its token)
- `POST /agent/webhook` - persist what the agent produced (HMAC-verified)
- `GET  /child/:childId/sessions` - a child's story history (requires the child token)
- `GET  /audio-url/:key` - signed URL for stored narration (replay)
- `GET  /share/:shareToken` - public HTML page for a saved story ("send to grandma")
- `POST /checkout` - start the EUR 8/month subscription (Mollie hosted checkout)
- `POST /payments/webhook` - Mollie payment callback; grants the subscription after re-fetching
  and confirming the payment status (never trusts the callback body)
- `GET  /healthz` - readiness probe reporting which dependencies are configured

Child-scoped routes require the `X-Child-Token` header (the primary per-request auth, minted at
onboarding and stored hashed). Write routes are rate-limited per IP; the free tier allows a few
stories per child, after which `POST /story` returns `402 subscription_required`. The optional
`X-Yarnia-Token` is a secondary network gate on top of the child token.

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

- `api/` has 138 passing unit tests plus integration tests (Vitest). Run `npm test` in `api/`.
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
- **Per-child auth (no bearer childId):** `POST /child` mints a per-child token and stores only
  its SHA-256 hash (`api/src/auth.ts`); the raw token is returned once and kept on-device. Every
  child-scoped route (`/story`, `/child/:id/sessions`, `/agent/session`) requires the matching
  `X-Child-Token`, so knowing a childId is no longer enough to read history or spend quota.
- **Rate limiting:** write routes (`/story`, `/child`, `/checkout`) are throttled per IP
  (`api/src/ratelimit.ts`); pair with Cloudflare account-level rules for durable enforcement.
- **Unguessable share links:** `/share` is keyed by a random `shareToken`, never the internal
  session id, and the HTML is escaped.
- **Content safety (defense in depth):** every story prompt carries an age-appropriate
  guardrail and avoids the child's named fears (`api/src/prompt.ts`); generated text is then
  re-checked by an output moderation pass (`api/src/safety.ts`) that regenerates once and falls
  back to a guaranteed-safe story if anything age-inappropriate slips through. Onboarding fields
  that feed the prompt are sanitized too, not just the per-request choice.
- **API access:** CORS is restricted to the app and marketing origins plus localhost (no
  wildcard). An optional shared secret gates every product route: set `YARNIA_API_TOKEN` on the
  Worker and build the client with `--dart-define=API_TOKEN=...`, and the app sends a matching
  `X-Yarnia-Token` header on every call (left unset, the API is open and nothing breaks). The
  webhook stays on its own HMAC check (5-minute replay window). User-supplied story `choice`
  text is length-capped and stripped of prompt-delimiter characters before it reaches the LLM.
  For abuse protection in production, enable Cloudflare's rate-limiting rules on the
  `api.yarnia.quest` route (zero-config, set in the Cloudflare dashboard).

## Reliability and graceful degradation

- If the live ElevenLabs voice agent can't run (microphone denied, network, or agent error),
  the app falls back to a tap/voice co-creation screen that generates and narrates a story via
  `POST /story`, so the bedtime ritual still completes.
- Narration is an enhancement: TTS calls retry transient failures with backoff
  (`api/src/synthesize.ts`), and if it still fails the story returns as text (`audio: null`).
- Stories are shareable: `GET /share/:shareToken` serves a public, self-contained HTML page
  (story text plus an audio player) so "send to grandma" links open the actual story.
- Session persistence is webhook-first (survives the phone locking); the client confirms with
  a backoff poll rather than a tight loop.
- **Observability:** every request path emits structured JSON logs, and errors/analytics
  (`story_created` with token + estimated USD cost, `child_created`, `checkout_*`,
  `subscription_activated`) are forwarded to optional `ERROR_WEBHOOK` / `ANALYTICS_WEBHOOK`
  collectors (`api/src/observability.ts`). `GET /healthz` reports dependency readiness for an
  uptime monitor.
- **Cost control:** each story's marginal LLM + TTS spend is estimated and logged
  (`api/src/usage.ts`), and a free-tier quota caps runaway spend on unpaid accounts.
- **Offline-friendly replay:** narration mp3s are cached on-device after first play, so past
  stories replay from history without re-downloading.

## Pricing and monetization

EUR 8/month, positioned below the "do I really need this" threshold (Spotify EUR 10, Calm
EUR 8). Payments are live via Mollie and **enforced**: every child gets a small free tier, then
`POST /story` returns `402 subscription_required` until they subscribe. `POST /checkout` returns
a hosted-checkout URL (set `MOLLIE_API_KEY`, or a static `MOLLIE_PAYMENT_LINK` fallback) with the
childId in metadata; `POST /payments/webhook` confirms the payment with Mollie and flips the
child to subscribed. The app surfaces a "Unlock unlimited nights · EUR 8/mo" subscribe flow.

## Known limitations / roadmap

- Recurring billing uses Mollie's first-payment checkout; full subscription lifecycle
  (renewals, dunning, customer portal) is the next step.
- Ambient soundscapes, adult wind-down stories, and public story publishing are designed but
  not in the core demo build.
- The in-isolate rate limiter is best-effort; production should also enable Cloudflare
  account-level rate-limiting rules on the `api.yarnia.quest` route.

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
