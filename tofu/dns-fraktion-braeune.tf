# fraktion-braeune.de: privates Spaßprojekt, eigene Domain bei Strato, Zone liegt hier.
# Nameserver bei Strato: siehe Output "nameserver_fraktion_braeune".
resource "hcloud_zone" "fraktion_braeune" {
  name              = "fraktion-braeune.de"
  mode              = "primary"
  ttl               = 3600
  delete_protection = true
}

locals {
  zone_fb = hcloud_zone.fraktion_braeune.name
}

resource "hcloud_zone_rrset" "fb_apex_a" {
  zone    = local.zone_fb
  name    = "@"
  type    = "A"
  records = [{ value = local.ipv4, comment = "web" }]
}

resource "hcloud_zone_rrset" "fb_apex_aaaa" {
  zone    = local.zone_fb
  name    = "@"
  type    = "AAAA"
  records = [{ value = local.ipv6, comment = "web" }]
}

resource "hcloud_zone_rrset" "fb_www" {
  zone    = local.zone_fb
  name    = "www"
  type    = "CNAME"
  records = [{ value = "fraktion-braeune.de." }]
}

resource "hcloud_zone_rrset" "fb_caa" {
  zone = local.zone_fb
  name = "@"
  type = "CAA"
  records = [
    { value = "0 issue \"letsencrypt.org\"" },
    { value = "0 issue \"sectigo.com\"" },
  ]
}

# ---------- Mail: 1:1 von Strato übernommen ----------

resource "hcloud_zone_rrset" "fb_mx" {
  zone    = local.zone_fb
  name    = "@"
  type    = "MX"
  records = [{ value = "5 smtpin.rzone.de." }]
}

resource "hcloud_zone_rrset" "fb_dmarc" {
  zone    = local.zone_fb
  name    = "_dmarc"
  type    = "TXT"
  records = [{ value = provider::hcloud::txt_record("v=DMARC1;p=reject;") }]
}

# ---------- Verifizierung ----------

resource "hcloud_zone_rrset" "fb_txt" {
  zone    = local.zone_fb
  name    = "@"
  type    = "TXT"
  records = [{ value = provider::hcloud::txt_record("google-site-verification=TwO9WZIFx6viTVWqxQaGT1AjuX2CtJVuIBab8f4f-D0") }]
}
