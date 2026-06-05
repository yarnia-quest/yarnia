terraform {
  required_version = ">= 1.6"
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5"
    }
  }
}

# Auth: reads CLOUDFLARE_API_TOKEN from the environment. Never hardcode the token.
# Docs: https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs
provider "cloudflare" {}
