#!/usr/bin/env bash
# Richtet den SSH-Zugang des Backup-Dienstes zur Storage Box ein. Läuft lokal auf dem Mac.
#
# 1. Erzeugt auf dem Server einen eigenen Schlüssel (falls noch keiner da ist). Der private Teil
#    verlässt den Server nie; nach einem Neuaufbau einfach erneut ausführen.
# 2. Hinterlegt den öffentlichen Teil beim Unterkonto (backups/.ssh/authorized_keys), über das
#    Hauptkonto der Storage Box. Die Hetzner-API kann das für Unterkonten nicht.
#
# Idempotent: ein zweiter Aufruf ändert nichts, solange der Schlüssel existiert.
set -euo pipefail
cd "$(dirname "$0")/.."

ADMIN_USER="${ADMIN_USER:-hannes}"
ADMIN_KEY="${ADMIN_KEY:-$HOME/.ssh/hschaletzky_com_hetzner}"
DATEI=/opt/infra/secrets/backup_ssh_key

host="${SERVER:-$(tofu/run.sh output -raw ipv4)}"
box="$(tofu/run.sh output -raw storage_box_host)"
box_user="$(tofu/run.sh output -raw storage_box_user)"

# 0444 im Verzeichnis 0700 (deploy) wie die übrigen Secrets: Der Container liest als uid 1000.
oeffentlich="$(ssh -i "$ADMIN_KEY" "$ADMIN_USER@$host" "sudo sh -c '
  set -e
  install -d -m 700 -o deploy -g deploy /opt/infra/secrets
  if [ ! -f $DATEI ]; then
    ssh-keygen -q -t ed25519 -N \"\" -C backup@hschaletzky-web -f $DATEI
    chown deploy:deploy $DATEI $DATEI.pub
    chmod 444 $DATEI
    echo Neuer Schlüssel erzeugt >&2
  fi
  cat $DATEI.pub
'")"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
printf '%s\n' "$oeffentlich" >"$tmp"

sftp -P 23 -i "$ADMIN_KEY" -b - -o StrictHostKeyChecking=yes \
  -o UserKnownHostsFile=backup/known_hosts "$box_user@$box" >/dev/null <<EOF
-mkdir backups/.ssh
put $tmp backups/.ssh/authorized_keys
chmod 700 backups/.ssh
chmod 600 backups/.ssh/authorized_keys
EOF

echo "Fertig: $(ssh-keygen -lf "$tmp" | cut -d' ' -f2) ist beim Unterkonto hinterlegt."
