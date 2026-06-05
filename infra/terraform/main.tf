# Cloudflare infra for Yarnia (declarative). Provider v5.
# Manages ONLY zone settings. The marketing Worker (yarnia.quest) manages its own custom domain + DNS
# via wrangler on deploy; InstantDB schema/perms are managed by instant-cli. api.yarnia.quest is
# added when api/ ships (June 6). (We use Workers Static Assets, not Cloudflare Pages.)

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
