output "ipv4" {
  value = local.ipv4
}

output "ipv6" {
  value = local.ipv6
}

output "nameserver" {
  description = "Bei Strato als externe Nameserver eintragen"
  value       = hcloud_zone.hschaletzky.authoritative_nameservers.assigned
}
