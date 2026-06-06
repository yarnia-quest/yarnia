# infra — config, secrets, CI

- **Config source of truth:** repo-root `.env` (gitignored) + `.env.example` (committed). IDs/tokens live there.
- **CI/CD (`.github/workflows/`):**
  - `deploy.yml` — `cloudflare/wrangler-action@v3` deploys the `yarnia-marketing` Worker (page + assets) to `yarnia.quest` on push to `marketing/**`. No app secrets.
  - `deploy-api.yml` — typechecks + tests, then deploys the `yarnia-api` Worker to `api.yarnia.quest` on push to `api/**`. Worker secrets are set once via `wrangler secret put` and persist; CI only needs the Cloudflare deploy creds.
  - `deploy-app.yml` — builds the Flutter web client (`flutter build web`, prod backend baked in) and deploys it to `app.yarnia.quest` as an assets-only Worker (`yarnia-app`) on push to `app/flutter/**`. Holds no secret.
  - `push-schema.yml` — `instant-cli push schema/perms` to the InstantDB app on changes to `instant/**`.
- **Cloudflare zone settings:** managed via dashboard/API (SSL Full, Always Use HTTPS). The worker's custom domain + DNS are managed by wrangler on deploy. No Terraform.
- **Tokens:** `CLOUDFLARE_API_TOKEN` / `CLOUDFLARE_ACCOUNT_ID` for deploys; `INSTANT_ADMIN_TOKEN` (god-mode) used ONLY by schema CI; the public `INSTANT_APP_ID` lives in the page (the marketing worker holds no secret).

## GitHub repo secrets (Settings -> Secrets and variables -> Actions)
`CLOUDFLARE_API_TOKEN` · `CLOUDFLARE_ACCOUNT_ID` · `INSTANT_APP_ID` · `INSTANT_ADMIN_TOKEN`

(Names match `.env`, so the workflows pick them up with no edits.)
