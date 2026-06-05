# CLAUDE.md — Yarnia engineering guide

> Build/code guidance for this repo, auto-loaded every session. Keep it lean and engineering-focused.
> Strategy, rubric, pitch, and idea context live in `ideation/` (`STRATEGY.md`, `PLAN.md`, `YARNIA.md`, `DECK.md`) — read those when working on the pitch, not when coding.

**What we're building:** Yarnia — a screen-off voice app that tells a child a personalized bedtime story and remembers them across nights. One sentence: *"We help a parent at 8pm get their kid to sleep with a screen-off voice story that remembers their child."*

## Repo layout
- `app/` — the Yarnia app (Expo / React Native). The product frontend.
- `api/` — product backend (Cloudflare Worker): story gen + ElevenLabs TTS + InstantDB + content-safety guardrail.
- `marketing/` — landing page (`public/`) served by an assets-only Cloudflare Worker (`src/worker.ts`) at yarnia.quest. The signup writes client-side to InstantDB (no secret). **Deployed.**
- `infra/` — config / secrets / CI notes.
- `instant/` — InstantDB schema + permissions as code (applied by `push-schema.yml`).
- `ideation/` — strategy/pitch docs (not code).

## Domains
- `yarnia.quest` (apex) → **marketing** Worker (serves `marketing/public/`; the page writes signups directly to InstantDB via the public app id + a create-only permission).
- `api.yarnia.quest` → **app backend** (`api/`). Reserved; the marketing side must not use it.

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
- **Marketing (page + worker):** `cd marketing && npm install && npx wrangler deploy`. Local dev: `npx wrangler dev`. (CI: `deploy.yml` via wrangler-action.)
- **app / api:** _(to be added once scaffolded June 6 — e.g. `cd app && npm install && npx expo start`)._

## Conventions
- **Package manager: npm + Node ≥22** everywhere (local and CI). Commit `package-lock.json`. Don't use bun for project deps (gstack's own CLI runs on bun, that's separate).
- Match the style of surrounding code; keep diffs small and explicit.
- Prose/writing (READMEs, copy, messages): **no em dashes.**
- _(Team to provide: language/lint/format rules, file structure, naming, testing approach.)_

## Day-of integrity (build constraint)
- The product (`app/` + `api/`) is built **June 6** with real commit history from that day. No prebuilt product code, no faked history/demo/evidence. (`marketing/` + `ideation/` are allowed pre-event prep.)

## Official docs (read before using a tool; verified 2026-06-05)
- **Cloudflare Workers:** https://developers.cloudflare.com/workers/
- **Wrangler config** (vars, secrets, routes, custom_domain, compatibility flags): https://developers.cloudflare.com/workers/wrangler/configuration/
- **Workers routes:** https://developers.cloudflare.com/workers/configuration/routing/routes/
- **Cloudflare Pages:** https://developers.cloudflare.com/pages/ · custom domains: https://developers.cloudflare.com/pages/configuration/custom-domains/ · direct upload: https://developers.cloudflare.com/pages/get-started/direct-upload/
- **Cloudflare docs for LLMs:** https://developers.cloudflare.com/workers/llms.txt
- **InstantDB:** https://www.instantdb.com/docs · backend/admin SDK: https://www.instantdb.com/docs/backend · schema/modeling: https://www.instantdb.com/docs/modeling-data · permissions: https://www.instantdb.com/docs/permissions · **Platform API (IaC):** https://www.instantdb.com/docs/platform-api · CLI: https://www.instantdb.com/docs/cli
- **GitHub Actions:** https://docs.github.com/actions
- **Expo (client):** https://docs.expo.dev/
- **ElevenLabs (voice):** https://elevenlabs.io/docs · **OpenAI:** https://platform.openai.com/docs · **Qwen:** https://qwen.readthedocs.io/
- **Mollie (payments, if used):** https://docs.mollie.com/

Verified facts in use (2026-06-05). **Pattern (from prism):** one Worker with Static Assets per app — `[assets] directory binding=ASSETS` + the worker falls through to `env.ASSETS.fetch()`; deployed via `cloudflare/wrangler-action@v3`. Marketing: `[[routes]] pattern="yarnia.quest" custom_domain=true` (the worker serves the page; `api.yarnia.quest` is the app backend). **Client write (no token):** the page uses `@instantdb/core` `db.transact(db.tx.signups[id()].create({...}))` as a guest, gated by a `signups.create:true` permission (`view/update/delete:false`). **Admin token** (`@instantdb/admin`, bypasses perms) is used ONLY by schema CI: `instant-cli push schema/perms --app <id> --token <INSTANT_ADMIN_TOKEN> --yes` (the app admin token works as the CLI `--token`; no separate PAT). Schema: `i.entity({ email: i.string().unique().indexed(), ... })`. Tooling: use **Node ≥22** (nvm v24 here), not Bun, for wrangler.

## Deploy & automation
- **Marketing site:** `.github/workflows/deploy.yml` → `cloudflare/wrangler-action@v3` deploys the `yarnia-marketing` Worker (page + assets) to `yarnia.quest` on push to `marketing/**`. No app secrets (signup is client-side).
- **InstantDB schema/perms:** `.github/workflows/push-schema.yml` → `instant-cli push schema/perms --token <INSTANT_ADMIN_TOKEN>` on changes to `instant/**`.
- **Cloudflare zone settings:** managed via dashboard/API (SSL Full, Always Use HTTPS — already set). The worker's custom domain + DNS are managed by wrangler on deploy.
- **GitHub repo secrets:** `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID` (deploys); `INSTANT_APP_ID`, `INSTANT_ADMIN_TOKEN` (schema CI only). The marketing Worker holds NO secret.

## Tooling: gstack
- Both machines need the base install (`~/.claude/skills/gstack`, needs Bun). Gives `/office-hours`, `/plan-ceo-review`, `/review`, `/qa`, `/ship`. Optional team-mode repo bootstrap (`gstack-team-init optional`) can be run once on this repo. Full notes: `ideation/STRATEGY.md` history / `infra/README.md`.
