#!/usr/bin/env bash
# Überträgt Secrets aus dem macOS-Schlüsselbund nach /opt/infra/secrets/ auf dem Server.
# Läuft lokal auf dem Mac, per Admin-SSH (nicht mit dem Deploy-Schlüssel).
#
#   scripts/push-secrets.sh             überträgt alle Werte, bricht ab, wenn einer fehlt
#   scripts/push-secrets.sh --generate  erzeugt fehlende Datenbank-Passwörter vorher
#
# Der Schlüsselbund ist die Quelle der Wahrheit. Nach einem Server-Neuaufbau genügt ein Aufruf.
# Nicht hier: der SSH-Schlüssel für Backups (entsteht auf dem Server, scripts/backup-ssh-key.sh).
# GitHub-Werte von Hand anlegen (fragt nach dem Wert, landet nicht in der Shell-History):
#   security add-generic-password -a "$USER" -s hschaletzky-auth-github-client-id -w
#   security add-generic-password -a "$USER" -s hschaletzky-auth-github-client-secret -w
set -euo pipefail
cd "$(dirname "$0")/.."

ADMIN_USER="${ADMIN_USER:-hannes}"
ADMIN_KEY="${ADMIN_KEY:-$HOME/.ssh/hschaletzky_com_hetzner}"
ZIEL=/opt/infra/secrets

# "Datei auf dem Server:Eintrag im Schlüsselbund:erzeugbar" (macOS-Bash 3.2 kennt keine Hash-Arrays)
SECRETS=(
  pipeline_db_owner:hschaletzky-pipeline-db-owner:ja
  pipeline_db_app:hschaletzky-pipeline-db-app:ja
  pipeline_db_backup:hschaletzky-pipeline-db-backup:ja
  auth_db_owner:hschaletzky-auth-db-owner:ja
  auth_db_app:hschaletzky-auth-db-app:ja
  auth_secret:hschaletzky-auth-secret:ja
  auth_github_client_id:hschaletzky-auth-github-client-id:nein
  auth_github_client_secret:hschaletzky-auth-github-client-secret:nein
)

aus_schluesselbund() {
  security find-generic-password -a "$USER" -s "$1" -w 2>/dev/null
}

if [[ "${1:-}" == --generate ]]; then
  for zeile in "${SECRETS[@]}"; do
    IFS=: read -r _ eintrag erzeugbar <<< "$zeile"
    if [[ "$erzeugbar" == ja ]] && ! aus_schluesselbund "$eintrag" >/dev/null; then
      # 32 Zeichen ohne Sonderzeichen: unproblematisch in URLs und Shells
      wert="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 32)"
      security add-generic-password -a "$USER" -s "$eintrag" -w "$wert"
      echo "Erzeugt: $eintrag"
    fi
  done
fi

host="${SERVER:-$(tofu/run.sh output -raw ipv4)}"
ssh_admin() { ssh -i "$ADMIN_KEY" "$ADMIN_USER@$host" "$@"; }

ssh_admin "sudo install -d -m 700 -o deploy -g deploy $ZIEL"

for zeile in "${SECRETS[@]}"; do
  IFS=: read -r datei eintrag _ <<< "$zeile"
  wert="$(aus_schluesselbund "$eintrag")" || {
    echo "Kein Eintrag '$eintrag' im Schlüsselbund. Anlegen mit:" >&2
    echo "  security add-generic-password -a \"\$USER\" -s $eintrag -w" >&2
    exit 1
  }
  # 0444: Container lesen die Datei als eigener Nutzer (postgres, node). Geschützt ist sie
  # durch das Verzeichnis (0700, deploy), das nur in die Container eingehängt wird.
  printf %s "$wert" | ssh_admin "sudo sh -c 'umask 077; cat > $ZIEL/$datei.neu && chown deploy:deploy $ZIEL/$datei.neu && chmod 444 $ZIEL/$datei.neu && mv $ZIEL/$datei.neu $ZIEL/$datei'"
  echo "Übertragen: $datei"
done

echo "Fertig. Neue Werte wirken nach einem Deploy des betroffenen Dienstes (ssh deploy@$host deploy <dienst>)"
