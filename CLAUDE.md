# CLAUDE.md — Yarnia engineering guide

> Build/code guidance for this repo, auto-loaded every session. Keep it lean and engineering-focused.
> Strategy, rubric, pitch, and idea context live in `ideation/` (`STRATEGY.md`, `PLAN.md`, `YARNIA.md`, `DECK.md`) — read those when working on the pitch, not when coding.

**What we're building:** Yarnia — a screen-off voice app that tells a child a personalized bedtime story and remembers them across nights. One sentence: *"We help a parent at 8pm get their kid to sleep with a screen-off voice story that remembers their child."*

## Repo layout
- `client/` — the Yarnia app (Expo / React Native). The product frontend.
- `server/` — product backend (Cloudflare Worker): story gen + ElevenLabs TTS + InstantDB + content-safety guardrail.
- `marketing/` — waitlist landing page (`index.html`) + signup `worker/` (Cloudflare Worker → InstantDB). Already built.
- `infra/` — config, secrets, CI notes.
- `ideation/` — strategy/pitch docs (not code).

## Stack
- **Frontend:** Expo (React Native).
- **Backend:** Cloudflare Workers (thin layers; wrangler).
- **Data/auth/storage:** InstantDB.
- **Voice/TTS:** ElevenLabs. **Story gen:** OpenAI or Qwen.
- _(Team to confirm versions, package manager, and any other libraries.)_

## Config & secrets (important)
- **Single source of truth: repo-root `.env`** (gitignored) + `.env.example` (committed). All IDs/tokens live there.
- **Never hardcode** ids/tokens/keys in code, `wrangler.toml`, or the client. The public `INSTANT_APP_ID` is the only id safe to expose client-side; the InstantDB **admin token** and any API keys are server-side secrets only.
- Workers read secrets from env bindings: set via `wrangler secret put` locally or GitHub repo secrets in CI. Local `wrangler dev` uses `.dev.vars` (gitignored).
- GitHub repo secrets mirror the `.env` keys (see `infra/README.md`); CI in `.github/workflows/`.

## Commands
- **Marketing signup worker:** `cd marketing/worker && npm install && bash deploy.sh` (reads root `.env`). Local: `npm run dev`.
- **client / server:** _(to be added once scaffolded June 6 — e.g. `cd client && npm install && npx expo start`)._

## Conventions
- Match the style of surrounding code; keep diffs small and explicit.
- Prose/writing (READMEs, copy, messages): **no em dashes.**
- _(Team to provide: language/lint/format rules, file structure, naming, testing approach.)_

## Day-of integrity (build constraint)
- The product (`client/` + `server/`) is built **June 6** with real commit history from that day. No prebuilt product code, no faked history/demo/evidence. (`marketing/` + `ideation/` are allowed pre-event prep.)

## Tooling: gstack
- Both machines need the base install (`~/.claude/skills/gstack`, needs Bun). Gives `/office-hours`, `/plan-ceo-review`, `/review`, `/qa`, `/ship`. Optional team-mode repo bootstrap (`gstack-team-init optional`) can be run once on this repo. Full notes: `ideation/STRATEGY.md` history / `infra/README.md`.
