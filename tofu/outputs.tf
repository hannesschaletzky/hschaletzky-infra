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

output "storage_box_host" {
  description = "Adresse der Storage Box (SFTP, Port 23)"
  value       = hcloud_storage_box.backup.server
}

output "storage_box_user" {
  description = "Hauptkonto, für Restore vom Mac"
  value       = hcloud_storage_box.backup.username
}

output "storage_box_backup_user" {
  description = "Unterkonto für den Backup-Dienst auf dem Server"
  value       = hcloud_storage_box_subaccount.backup.username
}
