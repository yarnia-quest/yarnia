variable "cloudflare_account_id" {
  type        = string
  description = "Cloudflare account ID (identifier, not a secret)."
}

variable "cloudflare_zone_id" {
  type        = string
  description = "Cloudflare zone ID for the domain (identifier, not a secret)."
}

variable "domain" {
  type    = string
  default = "yarnia.quest"
}

variable "pages_project" {
  type    = string
  default = "yarnia"
}
