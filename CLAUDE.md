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
- **Voice/TTS:** ElevenLabs. **Story gen:** Qwen (DashScope OpenAI-compatible API, `qwen3.7-max`, intl endpoint).
- _(Team to confirm versions, package manager, and any other libraries.)_

## Config & secrets (important)
- **Two env files, split by trust boundary** (each `.env` gitignored, each `.env.example` committed):
  - **`api/.env`** (backend: `api/` Worker + `instant/`) — ALL secrets: `INSTANT_ADMIN_TOKEN`, `QWEN_API_KEY`, `ELEVENLABS_API_KEY`, Cloudflare deploy creds, plus the public `INSTANT_APP_ID`.
  - **`app/.env`** (frontend: Expo) — PUBLIC ONLY, every var prefixed `EXPO_PUBLIC_` (`EXPO_PUBLIC_INSTANT_APP_ID`, `EXPO_PUBLIC_API_BASE_URL`). **No secret may ever appear here** — this file ships inside the client bundle on the user's device.
- **Never hardcode** ids/tokens/keys in code, `wrangler.toml`, or the client. The public `INSTANT_APP_ID` is the only id safe client-side; the InstantDB **admin token** and any API keys are server-side only (so they live only in `api/.env`).
- Workers read secrets from env bindings: set via `wrangler secret put` locally or GitHub repo secrets in CI. `wrangler dev` reads `api/.dev.vars` (gitignored); `api/.env` is the source of truth and the api dev script loads it.
- GitHub repo secrets mirror the `api/.env` keys (see `infra/README.md`); CI in `.github/workflows/`.

## IMPORTANT — ElevenLabs conversational agent (prompts live in the dashboard, not the repo)
- The Yarnia agent's **System prompt + First message are edited in the ElevenLabs dashboard** (agent `agent_5201kte23jbef6ethe0448m7x46k`, project "Yarnia"), then **Published**. They are NOT stored in a repo file (`infra/elevenlabs-agent.md` was deleted on purpose). Do not recreate a prompt doc; give the user copy/paste text for the dashboard.
- The prompt may reference **ONLY** the dynamic variables the Worker emits via `toDynamicVariables` (`api/src/agent.ts`) / `GET /agent/session`: `{{child_name}}`, `{{child_age}}`, `{{favorite_characters}}`, `{{fears_to_avoid}}`, `{{last_story}}`, `{{session_state}}`, `{{active_story_series}}`, `{{last_series_episode}}`, `{{greeting}}`. Any other `{{var}}` renders empty/literal — add it to `toDynamicVariables` first, then to the prompt.
- **Anonymous starts are supported:** `GET /agent/session` works with NO `childId` (streaming voice may begin before we know who is listening). Then `child_name` is empty and `{{greeting}}` asks for the name. The first-message field should be just `{{greeting}}` (ElevenLabs can't branch; the if lives in `toDynamicVariables`). The system prompt must handle empty `{{child_name}}` by asking the name first and calling them "little one" until known. A given-but-unknown `childId` is still a 404.
- Builder settings: voice **Clara** (Relaxing/Calm), LLM **Qwen3.5-397B-A17B**, languages **English + German**; guardrails under **Settings** (not the prompt). Register variables in the **{ } Variables** panel.
- The app passes the live values from `GET /agent/session` (Worker-filled) when it starts the conversation. To change the prompt: keep the `{{var}}` set in sync with the emitter → register in { } Variables → **Publish**.

## Commands
- **Marketing (page + worker):** `cd marketing && npm install && npx wrangler deploy`. Local dev: `npx wrangler dev`. (CI: `deploy.yml` via wrangler-action.)
- **app / api:** _(to be added once scaffolded June 6 — e.g. `cd app && npm install && npx expo start`)._

## Parallel work & collaboration (git worktrees)
We work fast on `main` with multiple Claude Code sessions at once. To avoid clobbering each other (stash/index/working-tree collisions on a shared checkout), **each session works in its own git worktree on its own branch.** A worktree is a second working folder backed by the same `.git`, checked out to a different branch.
- **Make one:** `scripts/worktree-add.sh <branch-name> [base]` (runs from any checkout). It creates a sibling folder `yarnia-<branch>`, branches off `origin/<base>` (default `main`), and seeds the gitignored bits the api needs (`api/.env`, `api/.dev.vars`, and a `node_modules` symlink) so the api boots with no extra setup. Example: `scripts/worktree-add.sh fix/tts-retry`.
- **Use one:** open a session there with `cd ../yarnia-<branch> && claude`. Edit `api/` freely; every commit lands on that worktree's branch, never on a teammate's.
- **Keep the main checkout (`/…/yarnia` on `main`) clean** as the neutral integration spot. Do feature work in worktrees, not there.
- **Dev-server port (automatic):** `worktree-add.sh` assigns each worktree a unique port and writes it to `api/.dev.port` (gitignored). `npm run dev` and `npm run story` both read it, so two `npm run dev` sessions never clash and `npm run story` auto-targets the local server. The main checkout has no file and defaults to 8787. Override per-run with `API_BASE_URL=...` if needed.
- **node_modules is a symlink to main's** (one shared install). If a branch changes deps (edits `package.json`), break the link in that worktree and do a real install: `rm api/node_modules && cd api && npm install`.

### Landing your work (the remote is the source of truth)
Because all local worktrees share one `.git`, `origin/main` is what keeps teammates consistent. Branch off it, integrate through it.
- **Catch up on a teammate's merged work:** `git fetch origin && git rebase origin/main` (run in your worktree before continuing).
- **Land a feature:** `git push -u origin <branch>`, then merge on GitHub, or fast-forward directly with `git push origin HEAD:main` (succeeds only if `main` has not moved; if it has, rebase first).
- **Clean up after merge:** `git worktree remove ../yarnia-<branch>` then `git branch -d <branch>`. (`worktree remove` refuses if there are uncommitted changes; commit or push first.)
- List worktrees anytime with `git worktree list`.

## Conventions
- **Package manager: npm + Node 24 (LTS)** everywhere (local and CI). Commit `package-lock.json`. Don't use bun for project deps (gstack's own CLI runs on bun, that's separate).
- **Track every real lock file; never delete one that has a manifest.** A lock file paired with its manifest (`package-lock.json` next to a `package.json`, `pubspec.lock` next to `pubspec.yaml`, `skills-lock.json`) pins exact versions for reproducible builds and MUST be committed — never remove it, even if it looks sparse. The one exception: an *orphan* lock with no sibling manifest and no locked packages (e.g. an empty `package-lock.json` in a dir with no `package.json`) is cruft from a stray `npm` run — delete it. Real npm projects here: `api/`, `marketing/`, `instant/`, `app/expo/`, `app/astro/`. `app/flutter/` is Dart — it uses `pubspec.lock`, never `package-lock.json`.
- Match the style of surrounding code; keep diffs small and explicit.
- Prose/writing (READMEs, copy, messages): **no em dashes.**
- **Testing: TDD, red/green, atomic.** For each feature: write the failing test first (red), implement the minimum to pass (green), then refactor. Work in small increments; do NOT implement multiple features at once. `api/` tests run on **Vitest** via Hono's `app.request(path, init, env)` (in-process, no `wrangler dev`; inject fake bindings to mock OpenAI/ElevenLabs so tests cost nothing). `npm test` in `api/`.
- _(Team to provide: language/lint/format rules, file structure, naming.)_

## Day-of integrity (build constraint)
- The product (`app/` + `api/`) is built **June 6** with real commit history from that day. No prebuilt product code, no faked history/demo/evidence. (`marketing/` + `ideation/` are allowed pre-event prep.)

## Official docs (read before using a tool; verified 2026-06-05)
- **Cloudflare Workers:** https://developers.cloudflare.com/workers/
- **Hono on Cloudflare Workers** (the `api/` backend uses Hono — follow this guide): https://developers.cloudflare.com/workers/framework-guides/web-apps/more-web-frameworks/hono/ · **Workers bindings:** https://developers.cloudflare.com/workers/runtime-apis/bindings/
- **Hono framework:** https://hono.dev/docs/ · Cloudflare Workers guide: https://hono.dev/docs/getting-started/cloudflare-workers · routing: https://hono.dev/docs/api/routing · context (`c.req`/`c.json`/`c.env`): https://hono.dev/docs/api/context · middleware: https://hono.dev/docs/concepts/middleware · validation (zod): https://hono.dev/docs/guides/validation · **testing** (`app.request()`): https://hono.dev/docs/guides/testing
- **Vitest** (test runner — TDD red/green for `api/`): https://vitest.dev/guide/ · test API (`describe`/`it`/`expect`): https://vitest.dev/api/test · mocking (`vi.mock`/`vi.fn`, for OpenAI/ElevenLabs): https://vitest.dev/guide/mocking · CLI: https://vitest.dev/guide/cli
- **Wrangler config** (vars, secrets, routes, custom_domain, compatibility flags): https://developers.cloudflare.com/workers/wrangler/configuration/
- **Workers routes:** https://developers.cloudflare.com/workers/configuration/routing/routes/
- **Cloudflare Pages:** https://developers.cloudflare.com/pages/ · custom domains: https://developers.cloudflare.com/pages/configuration/custom-domains/ · direct upload: https://developers.cloudflare.com/pages/get-started/direct-upload/
- **Cloudflare docs for LLMs:** https://developers.cloudflare.com/workers/llms.txt
- **InstantDB:** https://www.instantdb.com/docs · backend/admin SDK: https://www.instantdb.com/docs/backend · schema/modeling: https://www.instantdb.com/docs/modeling-data · permissions: https://www.instantdb.com/docs/permissions · **Platform API (IaC):** https://www.instantdb.com/docs/platform-api · CLI: https://www.instantdb.com/docs/cli
- **GitHub Actions:** https://docs.github.com/actions
- **Expo (client):** https://docs.expo.dev/
- **ElevenLabs (voice):** https://elevenlabs.io/docs · single-shot TTS (used by `api/` `/story`): https://elevenlabs.io/docs/api-reference/text-to-speech/convert · **Agents (conversational):** quickstart https://elevenlabs.io/docs/eleven-agents/quickstart · prompting guide https://elevenlabs.io/docs/eleven-agents/best-practices/prompting-guide · guardrails https://elevenlabs.io/docs/eleven-agents/best-practices/guardrails · React/JS SDK `@elevenlabs/react` `@elevenlabs/client`. **Agent prompts live in the ElevenLabs dashboard, NOT the repo** — see the IMPORTANT note below.
- **Qwen (story gen — DashScope Model Studio, OpenAI-compatible):** OpenAI-compat guide: https://www.alibabacloud.com/help/en/model-studio/compatibility-of-openai-with-dashscope · get API key: https://www.alibabacloud.com/help/en/model-studio/get-api-key · models list: https://www.alibabacloud.com/help/en/model-studio/getting-started/models · first call: https://www.alibabacloud.com/help/en/model-studio/first-api-call-to-qwen · open-model docs: https://qwen.readthedocs.io/ · in use: base URL `https://dashscope-intl.aliyuncs.com/compatible-mode/v1`, model `qwen3.7-max` with `enable_thinking:false` (reasoning pass off — ~4s vs ~49s/timeout, no quality loss for stories), Bearer `QWEN_API_KEY`. (No reputable first-party Qwen text-gen agent skill on skills.sh as of 2026-06-06; the API is OpenAI-compatible so the OpenAI SDK applies: https://platform.openai.com/docs.)
- **Mollie (payments, if used):** https://docs.mollie.com/

Verified facts in use (2026-06-05). **Pattern (from prism):** one Worker with Static Assets per app — `[assets] directory binding=ASSETS` + the worker falls through to `env.ASSETS.fetch()`; deployed via `cloudflare/wrangler-action@v3`. Marketing: `[[routes]] pattern="yarnia.quest" custom_domain=true` (the worker serves the page; `api.yarnia.quest` is the app backend). **Client write (no token):** the page uses `@instantdb/core` `db.transact(db.tx.signups[id()].create({...}))` as a guest, gated by a `signups.create:true` permission (`view/update/delete:false`). **Admin token** (`@instantdb/admin`, bypasses perms) is used ONLY by schema CI: `instant-cli push schema/perms --app <id> --token <INSTANT_ADMIN_TOKEN> --yes` (the app admin token works as the CLI `--token`; no separate PAT). Schema: `i.entity({ email: i.string().unique().indexed(), ... })`. Tooling: use **Node 24 (LTS)**, not Bun, for wrangler. **Backend framework: Hono** — the `api/` Worker is a Hono app (`import { Hono } from 'hono'`; `export default app`); routes/middleware/validation per the Hono docs above.

## Deploy & automation
- **Marketing site:** `.github/workflows/deploy.yml` → `cloudflare/wrangler-action@v3` deploys the `yarnia-marketing` Worker (page + assets) to `yarnia.quest` on push to `marketing/**`. No app secrets (signup is client-side).
- **InstantDB schema/perms:** `.github/workflows/push-schema.yml` → `instant-cli push schema/perms --token <INSTANT_ADMIN_TOKEN>` on changes to `instant/**`.
- **Cloudflare zone settings:** managed via dashboard/API (SSL Full, Always Use HTTPS — already set). The worker's custom domain + DNS are managed by wrangler on deploy.
- **GitHub repo secrets:** `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID` (deploys); `INSTANT_APP_ID`, `INSTANT_ADMIN_TOKEN` (schema CI only). The marketing Worker holds NO secret.

## Tooling: gstack
- Both machines need the base install (`~/.claude/skills/gstack`, needs Bun). Gives `/office-hours`, `/plan-ceo-review`, `/review`, `/qa`, `/ship`. Optional team-mode repo bootstrap (`gstack-team-init optional`) can be run once on this repo. Full notes: `ideation/STRATEGY.md` history / `infra/README.md`.

## Tooling: agent skills
- **`skills-lock.json` is committed** (the pinned manifest, like `package-lock.json`); **`.agents/`** (the materialized copy, like `node_modules`) is gitignored. After pulling, restore the exact skill set with `npx skills experimental_install`.
- Add a new skill with `npx skills add <owner/repo> -y` (updates the lock; commit it). Currently pinned: the Hono skill (`yusukebe/hono-skill` — inline Hono API reference + `npx hono request` endpoint testing, by Hono's creator; https://skills.sh/yusukebe/hono-skill), the Vitest skill (`antfu/skills@vitest` — by a Vitest maintainer; https://skills.sh/antfu/skills), the ElevenLabs skills (`elevenlabs/skills@agents` + `@text-to-speech` — first-party), plus the design/marketing/instantdb skills.
