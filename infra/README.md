# infra — config, secrets, CI

- **Config source of truth:** repo-root `.env` (gitignored) + `.env.example` (committed). IDs/tokens live there.
- **CI/CD (`.github/workflows/`):**
  - `deploy.yml` — `cloudflare/wrangler-action@v3` deploys the `yarnia-marketing` Worker (page + assets) to `yarnia.quest` on push to `marketing/**`. No app secrets.
  - `push-schema.yml` — `instant-cli push schema/perms` to the InstantDB app on changes to `instant/**`.
- **Cloudflare zone settings:** managed via dashboard/API (SSL Full, Always Use HTTPS). The worker's custom domain + DNS are managed by wrangler on deploy. No Terraform.
- **Tokens:** `CLOUDFLARE_API_TOKEN` / `CLOUDFLARE_ACCOUNT_ID` for deploys; `INSTANT_ADMIN_TOKEN` (god-mode) used ONLY by schema CI; the public `INSTANT_APP_ID` lives in the page (the marketing worker holds no secret).

## GitHub repo secrets (Settings -> Secrets and variables -> Actions)
`CLOUDFLARE_API_TOKEN` · `CLOUDFLARE_ACCOUNT_ID` · `INSTANT_APP_ID` · `INSTANT_ADMIN_TOKEN`

(Names match `.env`, so the workflows pick them up with no edits.)
