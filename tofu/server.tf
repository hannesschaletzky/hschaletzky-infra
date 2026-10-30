resource "hcloud_ssh_key" "admin" {
  name       = "admin"
  public_key = file("${path.module}/keys/admin.pub")
}

# Feste Adressen, unabhängig vom Server: Ein Neuaufbau ändert weder IP noch DNS.
resource "hcloud_primary_ip" "v4" {
  name              = "web-v4"
  type              = "ipv4"
  location          = var.location
  auto_delete       = false
  delete_protection = true
}

resource "hcloud_primary_ip" "v6" {
  name              = "web-v6"
  type              = "ipv6"
  location          = var.location
  auto_delete       = false
  delete_protection = true
}

resource "hcloud_firewall" "web" {
  name = "web"

  rule {
    description = "SSH"
    direction   = "in"
    protocol    = "tcp"
    port        = "22"
    source_ips  = ["0.0.0.0/0", "::/0"]
  }
  rule {
    description = "HTTP"
    direction   = "in"
    protocol    = "tcp"
    port        = "80"
    source_ips  = ["0.0.0.0/0", "::/0"]
  }
  rule {
    description = "HTTPS"
    direction   = "in"
    protocol    = "tcp"
    port        = "443"
    source_ips  = ["0.0.0.0/0", "::/0"]
  }
  rule {
    description = "HTTP/3"
    direction   = "in"
    protocol    = "udp"
    port        = "443"
    source_ips  = ["0.0.0.0/0", "::/0"]
  }
  rule {
    description = "Ping"
    direction   = "in"
    protocol    = "icmp"
    source_ips  = ["0.0.0.0/0", "::/0"]
  }
}

# Der Server ist austauschbar: Alles Wichtige steckt in diesem Repo und in den Images.
# Neu aufbauen:  tofu apply -replace=hcloud_server.web
resource "hcloud_server" "web" {
  name         = "web"
  server_type  = var.server_type
  image        = "ubuntu-24.04"
  location     = var.location
  ssh_keys     = [hcloud_ssh_key.admin.id]
  firewall_ids = [hcloud_firewall.web.id]

  user_data = templatefile("${path.module}/cloud-init.yaml", {
    admin_user = var.admin_user
    admin_key  = trimspace(file("${path.module}/keys/admin.pub"))
    deploy_key = trimspace(file("${path.module}/keys/deploy.pub"))
  })

  public_net {
    ipv4_enabled = true
    ipv4         = hcloud_primary_ip.v4.id
    ipv6_enabled = true
    ipv6         = hcloud_primary_ip.v6.id
  }

  # cloud-init wirkt nur beim Erstellen. Spätere Änderungen daran sollen den Server nicht stillschweigend ersetzen.
  lifecycle {
    ignore_changes = [user_data, ssh_keys, image]
  }
}
