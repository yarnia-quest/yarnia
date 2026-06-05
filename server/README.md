# server — Yarnia product backend (Cloudflare Worker)

Built **June 6** (the product). Thin layer: story generation (OpenAI/Qwen) + ElevenLabs TTS + InstantDB writes; returns audio URLs to `client/`. Plus the content-safety guardrail (age/fear constraints) before any story reaches a child.

- Follows the same pattern as `marketing/worker/`: `wrangler.toml` with no hardcoded ids, secrets via `wrangler secret put` / GitHub repo secrets, config from repo-root `.env`.
- **Domain:** deploys to `api.yarnia.quest` (the app backend). The marketing waitlist worker is separate, on `signups.yarnia.quest` (`marketing/worker/`).
- Build plan: `ideation/YARNIA.md`.
