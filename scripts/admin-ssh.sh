#!/usr/bin/env bash
# Admin-SSH für die lokalen Skripte. Wird eingebunden (". scripts/admin-ssh.sh"), Aufruf dann mit
#   ssh "${ADMIN_SSH[@]}" "$ADMIN_USER@$host" …
#
# Der private Admin-Schlüssel liegt nur in Bitwarden (Eintrag hschaletzky-ssh-admin), nicht als Datei
# auf der Platte. Der SSH-Agent der Bitwarden-App gibt ihn heraus und fragt bei jeder Benutzung nach
# einer Bestätigung. -i zeigt deshalb auf den öffentlichen Teil: So wählt ssh genau diesen Schlüssel
# aus dem Agent.
ADMIN_USER="${ADMIN_USER:-hannes}"
ADMIN_KEY="${ADMIN_KEY:-tofu/keys/admin.pub}"
ADMIN_AGENT="${ADMIN_AGENT:-$HOME/.bitwarden-ssh-agent.sock}"

[[ -S "$ADMIN_AGENT" ]] || {
  echo "Der Bitwarden-SSH-Agent läuft nicht ($ADMIN_AGENT). Bitwarden-App öffnen, entsperren und" >&2
  echo "in den Einstellungen 'SSH-Agent aktivieren' einschalten." >&2
  exit 1
}

# shellcheck disable=SC2034  # wird von den einbindenden Skripten benutzt
ADMIN_SSH=(-i "$ADMIN_KEY" -o IdentityAgent="$ADMIN_AGENT" -o IdentitiesOnly=yes)
