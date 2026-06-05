# Cloudflare infra for Yarnia (declarative, one-time-ish). Provider v5.
# Manages: zone settings, the marketing Pages project + apex/www custom domains + their DNS.
# Does NOT manage (avoid conflicts):
#   - the signup Worker + signups.yarnia.quest  -> owned by wrangler (marketing/worker/wrangler.toml)
#   - InstantDB schema                          -> owned by instant-cli
#   - api.yarnia.quest                          -> add when api/ ships (June 6)

# --- Zone settings ---
resource "cloudflare_zone_setting" "ssl" {
  zone_id    = var.cloudflare_zone_id
  setting_id = "ssl"
  value      = "full"
}

resource "cloudflare_zone_setting" "always_https" {
  zone_id    = var.cloudflare_zone_id
  setting_id = "always_use_https"
  value      = "on"
}

# --- Marketing site on Cloudflare Pages (direct upload; content pushed by the deploy-pages GitHub Action) ---
resource "cloudflare_pages_project" "marketing" {
  account_id        = var.cloudflare_account_id
  name              = var.pages_project
  production_branch = "main"
}

# Attach apex + www to the Pages project (does not create DNS by itself)
resource "cloudflare_pages_domain" "apex" {
  account_id   = var.cloudflare_account_id
  project_name = cloudflare_pages_project.marketing.name
  name         = var.domain
}

resource "cloudflare_pages_domain" "www" {
  account_id   = var.cloudflare_account_id
  project_name = cloudflare_pages_project.marketing.name
  name         = "www.${var.domain}"
}

# --- DNS for the Pages domains (CNAME flattening handles the apex) ---
resource "cloudflare_dns_record" "apex" {
  zone_id = var.cloudflare_zone_id
  name    = var.domain
  type    = "CNAME"
  content = "${var.pages_project}.pages.dev"
  proxied = true
  ttl     = 1
}

resource "cloudflare_dns_record" "www" {
  zone_id = var.cloudflare_zone_id
  name    = "www.${var.domain}"
  type    = "CNAME"
  content = "${var.pages_project}.pages.dev"
  proxied = true
  ttl     = 1
}

output "pages_subdomain" {
  value = "${var.pages_project}.pages.dev"
}
