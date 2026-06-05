# infra — config, secrets, deployment

- **Config source of truth:** repo-root `.env` (gitignored) + `.env.example` (committed). All IDs and tokens live there.
- **CI/CD:** `.github/workflows/` deploys Workers using GitHub repo secrets that mirror the `.env` keys.
- **Cloudflare:** `CLOUDFLARE_ACCOUNT_ID` / `CLOUDFLARE_ZONE_ID` are identifiers (fine in `.env`); `CLOUDFLARE_API_TOKEN` is a secret (CI only; local uses `wrangler login`).
- **InstantDB:** `INSTANT_APP_ID` is public; `INSTANT_ADMIN_TOKEN` is a secret used server-side by Workers.

## Add these as GitHub repo secrets (Settings -> Secrets and variables -> Actions)
`CLOUDFLARE_ACCOUNT_ID` · `CLOUDFLARE_API_TOKEN` · `INSTANT_APP_ID` · `INSTANT_ADMIN_TOKEN`

(The names match `.env` exactly, so the workflows pick them up with no edits.)
