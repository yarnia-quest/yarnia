# Yarnia signups — Cloudflare Worker + InstantDB

Captures landing-page email signups. The static page (`../index.html`) POSTs `{email}` here; this Worker writes it to InstantDB using the **admin token**, kept server-side (never in code/repo). All ids/secrets come from the repo-root `.env` (see `.env.example`).

## One-time: add the `signups` entity to your InstantDB schema
In your InstantDB project (App ID in `.env`), add to `instant.schema.ts`:

```ts
signups: i.entity({
  email: i.string().unique().indexed(),
  createdAt: i.number(),
  source: i.string().optional(),
}),
```

Then push it: `npx instant-cli@latest push schema`. (The unique `email` index lets the Worker upsert instead of erroring on duplicates.)

## Get the ADMIN token (not the CLI token)
The Worker needs the app's **Admin SDK token**: InstantDB dashboard → your app → **Admin SDK**. This differs from the CLI/personal token used by `create-instant-app`. Put it in `.env` as `INSTANT_ADMIN_TOKEN`.

## Deploy — local (≈3 min)
Fill in repo-root `.env` (`CLOUDFLARE_ACCOUNT_ID`, `INSTANT_APP_ID`, `INSTANT_ADMIN_TOKEN`), then:
```bash
cd marketing/worker
npm install
npx wrangler login        # one-time browser auth (or set CLOUDFLARE_API_TOKEN in .env)
bash deploy.sh            # reads .env, sets the secret, deploys with the app id as a --var
```
`wrangler.toml` serves the Worker at **`https://api.yarnia.quest`** (a Worker custom domain — Cloudflare provisions DNS + cert on deploy; requires `yarnia.quest` to be an active zone in the account). The form action in `../index.html` already points there. To use the free `*.workers.dev` URL instead, delete the `[[routes]]` block and set the form action to the printed `workers.dev` URL.

Lock CORS to the site once it's live: `bash deploy.sh` then redeploy with `npx wrangler deploy --var ALLOWED_ORIGINS:https://yarnia.quest` (the Worker defaults to open CORS if unset).

## Deploy — CI (GitHub)
Add the four repo secrets (see `infra/README.md`): `CLOUDFLARE_ACCOUNT_ID`, `CLOUDFLARE_API_TOKEN`, `INSTANT_APP_ID`, `INSTANT_ADMIN_TOKEN`. Then `.github/workflows/deploy-worker.yml` deploys on push to `marketing/worker/**` (or via "Run workflow").

## Local dev (optional)
Create `marketing/worker/.dev.vars` (gitignored) with `INSTANT_APP_ID=...` and `INSTANT_ADMIN_TOKEN=...`, then `npm run dev`.

## Deploy the page
Static host. On Cloudflare Pages: point it at the `marketing/` folder (no build step). Then drop the URL into the Discord post + team-board tagline.

## Security (read once)
- `INSTANT_ADMIN_TOKEN` / `CLOUDFLARE_API_TOKEN` are **secrets**: only via `.env` (gitignored), `wrangler secret put`, or GitHub repo secrets. Never in `wrangler.toml`, the page, or any committed file.
- The InstantDB token shared in chat should be rotated after the event.
- `INSTANT_APP_ID` and the Cloudflare account/zone IDs are identifiers, not secrets.
- CORS currently echoes the request origin (open). Fine for the hackathon; tighten to your Pages domain later.
