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

## Domains (keep marketing and app cleanly separate)
- `yarnia.quest` (naked/apex) → **marketing** landing page (Cloudflare Pages, serves `marketing/`).
- `signups.yarnia.quest` → **marketing** waitlist Worker (`marketing/worker/`).
- `api.yarnia.quest` → **app backend** (`server/`). Reserved; the marketing side must not use it.

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

## Official docs (read before using a tool; verified 2026-06-05)
- **Cloudflare Workers:** https://developers.cloudflare.com/workers/
- **Wrangler config** (vars, secrets, routes, custom_domain, compatibility flags): https://developers.cloudflare.com/workers/wrangler/configuration/
- **Workers routes:** https://developers.cloudflare.com/workers/configuration/routing/routes/
- **Cloudflare Pages:** https://developers.cloudflare.com/pages/ · custom domains: https://developers.cloudflare.com/pages/configuration/custom-domains/ · direct upload: https://developers.cloudflare.com/pages/get-started/direct-upload/
- **Cloudflare docs for LLMs:** https://developers.cloudflare.com/workers/llms.txt
- **InstantDB:** https://www.instantdb.com/docs · backend/admin SDK: https://www.instantdb.com/docs/backend · schema/modeling: https://www.instantdb.com/docs/modeling-data · permissions: https://www.instantdb.com/docs/permissions · **Platform API (IaC):** https://www.instantdb.com/docs/platform-api · CLI: https://www.instantdb.com/docs/cli
- **Terraform:** https://developer.hashicorp.com/terraform/docs · **Cloudflare provider (v5):** https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs
- **GitHub Actions:** https://docs.github.com/actions
- **Expo (client):** https://docs.expo.dev/
- **ElevenLabs (voice):** https://elevenlabs.io/docs · **OpenAI:** https://platform.openai.com/docs · **Qwen:** https://qwen.readthedocs.io/
- **Mollie (payments, if used):** https://docs.mollie.com/

Verified facts in use: InstantDB admin `init({appId, adminToken})` + `db.transact([db.tx.X[lookup('attr', val)].update({...})])` (SDK uses `fetch`, runs on Workers). Schema: `i.entity({ email: i.string().unique().indexed(), ... })`, push with `npx instant-cli@latest push schema`. Wrangler custom domain: `[[routes]] pattern="signups.yarnia.quest" custom_domain=true` (marketing waitlist worker; `api.yarnia.quest` is the app backend). InstantDB schema in CI: `instant-cli push schema --token <per_…>` (Personal Access Token from dashboard settings); Platform SDK is `@instantdb/platform`. Terraform Cloudflare provider `~> 5` resources: `cloudflare_zone_setting`, `cloudflare_pages_project`, `cloudflare_pages_domain`, `cloudflare_dns_record`.

## Deploy & automation
- **Cloudflare infra (declarative):** `infra/terraform/` — zone settings, Pages project, apex/www domains + DNS. Run locally: `terraform apply` with `CLOUDFLARE_API_TOKEN` in env (state is local for now).
- **Marketing page:** `.github/workflows/deploy-marketing.yml` → `wrangler pages deploy marketing` on push to `marketing/**`.
- **Signup Worker:** `.github/workflows/deploy-worker.yml` (+ `marketing/worker/deploy.sh`) → wrangler; serves `signups.yarnia.quest`.
- **InstantDB schema/perms:** `.github/workflows/push-schema.yml` → `instant-cli push schema/perms --token` on changes to `instant.schema.ts`/`instant.perms.ts`.
- **GitHub repo secrets (mirror `.env`):** `CLOUDFLARE_ACCOUNT_ID`, `CLOUDFLARE_API_TOKEN`, `INSTANT_APP_ID`, `INSTANT_ADMIN_TOKEN` (worker runtime), `INSTANT_PERSONAL_ACCESS_TOKEN` (`per_…`, for schema CI).

## Tooling: gstack
- Both machines need the base install (`~/.claude/skills/gstack`, needs Bun). Gives `/office-hours`, `/plan-ceo-review`, `/review`, `/qa`, `/ship`. Optional team-mode repo bootstrap (`gstack-team-init optional`) can be run once on this repo. Full notes: `ideation/STRATEGY.md` history / `infra/README.md`.
