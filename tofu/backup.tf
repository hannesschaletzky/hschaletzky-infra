# Backup-Ziel: Hetzner Storage Box. Bewusst in einem anderen Rechenzentrum als der Server
# (BX11 gibt es nur in fsn1 und hel1, der Server steht in nbg1).
#
# Zugänge:
#   Hauptkonto   – für mich (Restore vom Mac), Login per admin-SSH-Key, auch von außen erreichbar
#   Unterkonto   – für den Backup-Dienst auf dem Server, nur Verzeichnis backups/, nur aus dem
#                  Hetzner-Netz. Den SSH-Key des Servers lege ich beim Einrichten des
#                  Backup-Dienstes in backups/.ssh/authorized_keys ab (die API kann das nicht).
#
# Snapshots macht die Box selbst. Der Server kann sie weder sehen noch löschen: Selbst wenn er
# übernommen wird und die Dateien in backups/ löscht, bleiben die Snapshots der letzten Tage.

variable "backup_location" {
  description = "Standort der Storage Box (BX11 nur fsn1 oder hel1)"
  type        = string
  default     = "fsn1"
}

# Passwörter landen nur im (verschlüsselten) State. Nur Zeichen, mit denen SFTP-, rclone- und
# Shell-Clients keine Probleme haben.
resource "random_password" "storage_box" {
  length           = 40
  min_upper        = 1
  min_lower        = 1
  min_numeric      = 1
  min_special      = 1
  override_special = "-_."
}

resource "random_password" "storage_box_backup" {
  length           = 40
  min_upper        = 1
  min_lower        = 1
  min_numeric      = 1
  min_special      = 1
  override_special = "-_."
}

resource "hcloud_storage_box" "backup" {
  name              = "backup"
  storage_box_type  = "bx11"
  location          = var.backup_location
  password          = random_password.storage_box.result
  ssh_keys          = [trimspace(file("${path.module}/keys/admin.pub"))]
  delete_protection = true

  access_settings = {
    ssh_enabled          = true
    reachable_externally = true
    samba_enabled        = false
    webdav_enabled       = false
    zfs_enabled          = true # Snapshots unter .zfs/ lesbar: Restore einzelner Stände ohne Rollback
  }

  # Täglich um 04:00 UTC, nach dem nächtlichen Backup. BX11 erlaubt höchstens 10 Snapshots.
  snapshot_plan = {
    hour          = 4
    minute        = 0
    max_snapshots = 10
  }

  lifecycle {
    # delete_protection greift nicht gegen tofu selbst
    prevent_destroy = true
    # SSH-Keys lassen sich per API nicht ändern; eine Änderung würde die Box neu anlegen
    ignore_changes = [ssh_keys]
  }
}

resource "hcloud_storage_box_subaccount" "backup" {
  storage_box_id = hcloud_storage_box.backup.id
  name           = "server-backup"
  description    = "Backup-Dienst auf dem Webserver"
  home_directory = "backups"
  password       = random_password.storage_box_backup.result

  access_settings = {
    ssh_enabled          = true
    reachable_externally = false
    samba_enabled        = false
    webdav_enabled       = false
    readonly             = false
  }
}
