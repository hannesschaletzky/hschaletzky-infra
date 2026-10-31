#!/usr/bin/env bash
# tofu mit Zugangsdaten aus dem macOS-Schlüsselbund, damit nichts im Klartext auf der Platte liegt.
#
# Einmalig ablegen (fragt nach dem Wert, landet nicht in der Shell-History):
#   security add-generic-password -a "$USER" -s hschaletzky-hcloud-token -w
#   security add-generic-password -a "$USER" -s hschaletzky-tofu-passphrase -w
#
# Danach:  ./run.sh plan   ./run.sh apply   ./run.sh output -raw ipv4
set -euo pipefail
cd "$(dirname "$0")"

aus_schluesselbund() {
  local wert
  wert="$(security find-generic-password -a "$USER" -s "$1" -w 2>/dev/null)" || {
    echo "Kein Eintrag '$1' im Schlüsselbund. Anlegen mit:" >&2
    echo "  security add-generic-password -a \"\$USER\" -s $1 -w" >&2
    exit 1
  }
  # Enthält der Wert Zeichen außerhalb von ASCII (ä, ß, €), gibt security ihn als Hex aus: zurückwandeln
  if [[ "$wert" =~ ^[0-9a-f]+$ && $((${#wert} % 2)) -eq 0 ]]; then
    wert="$(printf %s "$wert" | xxd -r -p)"
  fi
  printf %s "$wert"
}

HCLOUD_TOKEN="$(aus_schluesselbund hschaletzky-hcloud-token)"
TF_VAR_state_passphrase="$(aus_schluesselbund hschaletzky-tofu-passphrase)"
export HCLOUD_TOKEN TF_VAR_state_passphrase

exec tofu "$@"
