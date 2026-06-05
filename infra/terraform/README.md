# infra/terraform — Cloudflare infra as code (provider v5)

Manages the declarative Cloudflare resources: zone settings (SSL Full, Always Use HTTPS), the marketing **Pages project**, the **apex + www custom domains**, and their **DNS**.

**Not managed here (to avoid conflicts):**
- signup Worker + `signups.yarnia.quest` → wrangler (`marketing/worker/`)
- InstantDB schema/perms → `instant-cli` / Platform API (see schema workflow)
- `api.yarnia.quest` → add when `server/` ships

## Prereqs
- Terraform >= 1.6 (or OpenTofu): `brew install terraform`.
- A **Cloudflare API token** (dashboard → My Profile → API Tokens → Create Token) with:
  - **Account** → Cloudflare Pages: Edit · Account Settings: Read
  - **Zone** (scoped to yarnia.quest) → DNS: Edit · Zone Settings: Edit

## Run (local, one operator)
```bash
cd infra/terraform
cp terraform.tfvars.example terraform.tfvars   # fill account_id + zone_id (identifiers)
export CLOUDFLARE_API_TOKEN=...                # the secret token — never commit
terraform init
terraform plan                                 # REVIEW before applying (this stack is untested locally)
terraform apply
```

## State
Local `terraform.tfstate` (gitignored — may contain sensitive values). For a 1-day project, one person runs `apply`. To run Terraform from CI or share state across machines, add a remote backend (Cloudflare R2 S3-compatible, or Terraform Cloud) — ask and it'll be wired.

## After apply
- Page content is pushed by the **deploy-marketing** GitHub Action (`wrangler pages deploy marketing`), or run it locally.
- The signup Worker deploys from `marketing/worker/` (`bash deploy.sh` / its own Action).
