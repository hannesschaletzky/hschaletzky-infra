# Die Domain ist bei Strato registriert, die Zone liegt hier. Nameserver bei Strato: siehe Output "nameserver".
resource "hcloud_zone" "hschaletzky" {
  name              = "hschaletzky.com"
  mode              = "primary"
  ttl               = 3600
  delete_protection = true
}

locals {
  zone = hcloud_zone.hschaletzky.name
  ipv4 = hcloud_primary_ip.v4.ip_address
  ipv6 = cidrhost(hcloud_primary_ip.v6.ip_network, 1)
}

# ---------- Websites ----------

resource "hcloud_zone_rrset" "apex_a" {
  zone    = local.zone
  name    = "@"
  type    = "A"
  records = [{ value = var.hschaletzky_auf_server ? local.ipv4 : "76.76.21.21", comment = var.hschaletzky_auf_server ? "web" : "Vercel" }]
}

resource "hcloud_zone_rrset" "apex_aaaa" {
  count   = var.hschaletzky_auf_server ? 1 : 0
  zone    = local.zone
  name    = "@"
  type    = "AAAA"
  records = [{ value = local.ipv6, comment = "web" }]
}

resource "hcloud_zone_rrset" "www" {
  zone    = local.zone
  name    = "www"
  type    = "CNAME"
  records = [{ value = "hschaletzky.com." }]
}

resource "hcloud_zone_rrset" "tischlerei_a" {
  zone    = local.zone
  name    = "tischlerei-mustermann"
  type    = "A"
  records = [{ value = local.ipv4, comment = "web" }]
}

resource "hcloud_zone_rrset" "tischlerei_aaaa" {
  zone    = local.zone
  name    = "tischlerei-mustermann"
  type    = "AAAA"
  records = [{ value = local.ipv6, comment = "web" }]
}

resource "hcloud_zone_rrset" "sv_musterstadt_a" {
  zone    = local.zone
  name    = "sv-musterstadt"
  type    = "A"
  records = [{ value = local.ipv4, comment = "web" }]
}

resource "hcloud_zone_rrset" "sv_musterstadt_aaaa" {
  zone    = local.zone
  name    = "sv-musterstadt"
  type    = "AAAA"
  records = [{ value = local.ipv6, comment = "web" }]
}

resource "hcloud_zone_rrset" "physio_musterfrau_a" {
  zone    = local.zone
  name    = "physio-musterfrau"
  type    = "A"
  records = [{ value = local.ipv4, comment = "web" }]
}

resource "hcloud_zone_rrset" "physio_musterfrau_aaaa" {
  zone    = local.zone
  name    = "physio-musterfrau"
  type    = "AAAA"
  records = [{ value = local.ipv6, comment = "web" }]
}

# Nur diese CAs dürfen Zertifikate ausstellen: Let's Encrypt (Caddy, Vercel) und ZeroSSL/Sectigo (Caddys Fallback)
resource "hcloud_zone_rrset" "caa" {
  zone = local.zone
  name = "@"
  type = "CAA"
  records = [
    { value = "0 issue \"letsencrypt.org\"" },
    { value = "0 issue \"sectigo.com\"" },
  ]
}

# ---------- Mail (Microsoft 365), 1:1 von Strato übernommen ----------

resource "hcloud_zone_rrset" "mx" {
  zone    = local.zone
  name    = "@"
  type    = "MX"
  records = [{ value = "10 hschaletzky-com.mail.protection.outlook.com." }]
}

resource "hcloud_zone_rrset" "txt" {
  zone = local.zone
  name = "@"
  type = "TXT"
  records = [
    { value = provider::hcloud::txt_record("v=spf1 include:spf.protection.outlook.com -all") },
    { value = provider::hcloud::txt_record("google-site-verification=R35z4aAvP-V4pM4Md5Yzd9BJ0cpGo48jtDLn3T6rlTc") },
  ]
}

resource "hcloud_zone_rrset" "dmarc" {
  zone    = local.zone
  name    = "_dmarc"
  type    = "TXT"
  records = [{ value = provider::hcloud::txt_record("v=DMARC1;p=reject;") }]
}

resource "hcloud_zone_rrset" "autodiscover" {
  zone    = local.zone
  name    = "autodiscover"
  type    = "CNAME"
  records = [{ value = "autodiscover.outlook.com." }]
}
