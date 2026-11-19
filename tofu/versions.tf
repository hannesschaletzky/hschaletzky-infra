terraform {
  required_version = ">= 1.10"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.70"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
    # 2.0.0 wurde kurz veröffentlicht und wieder entfernt, deshalb die Obergrenze
    uptimerobot = {
      source  = "uptimerobot/uptimerobot"
      version = ">= 1.13.1, < 2.0.0"
    }
  }

  # Der State liegt verschlüsselt im Repo (terraform.tfstate). Ohne Passphrase ist er unlesbar,
  # und unverschlüsselt kann er gar nicht erst geschrieben werden.
  encryption {
    key_provider "pbkdf2" "passphrase" {
      passphrase = var.state_passphrase
    }
    method "aes_gcm" "standard" {
      keys = key_provider.pbkdf2.passphrase
    }
    state {
      method   = method.aes_gcm.standard
      enforced = true
    }
    plan {
      method   = method.aes_gcm.standard
      enforced = true
    }
  }
}

# Token kommt aus der Umgebung: HCLOUD_TOKEN
provider "hcloud" {}

# Schlüssel kommt aus der Umgebung: UPTIMEROBOT_API_KEY (tofu/run.sh)
provider "uptimerobot" {}
