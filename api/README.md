# server — Yarnia product backend (Cloudflare Worker, Hono)

Built **June 6** (the product). Thin [Hono](https://hono.dev/docs/getting-started/cloudflare-workers) Worker: story generation (Qwen) + ElevenLabs TTS + InstantDB writes; returns audio + text to `app/`. Plus the content-safety guardrail (age/fear constraints) before any story reaches a child.

## Run
```sh
cd api
npm install
npm run dev        # wrangler dev; predev copies api/.env -> api/.dev.vars for local secrets
npm run typecheck  # tsc --noEmit
npm run deploy     # wrangler deploy -> api.yarnia.quest
```

## Endpoints
- `GET /` — health check.
- `POST /story` — `{ childId, choice? }` -> `{ childId, choice, text, audio, status }`. Frozen contract; pipeline wired in across the day.
- `GET /agent/session?childId=...` — start a conversational ElevenLabs Agent session. `childId` is optional (anonymous voice can start before we know the child). Returns `{ agentId, dynamicVariables, signedUrl }`; `signedUrl` may be `null` (public agent / signing unavailable).

## Config
- Secrets live in **`api/.env`** (gitignored; template `api/.env.example`): `QWEN_API_KEY`, `ELEVENLABS_API_KEY`, `ELEVENLABS_AGENT_ID`, `INSTANT_ADMIN_TOKEN`, `INSTANT_APP_ID`. Never hardcode them or put them in `app/`.
- Local dev: `npm run dev` generates `api/.dev.vars` from `api/.env` (wrangler reads `.dev.vars`). Production: `wrangler secret put` / GitHub Actions secrets.
- **Domain:** `api.yarnia.quest`. The marketing waitlist worker is separate, on the apex (`marketing/`).
- Build plan: `ideation/YARNIA.md` · day split: `ideation/BUILD-DAY.md`.
