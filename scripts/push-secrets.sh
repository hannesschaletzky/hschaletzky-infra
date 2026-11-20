#!/usr/bin/env bash
# Überträgt Secrets aus dem Infra-Schlüsselbund (scripts/schluesselbund.sh) nach /opt/infra/secrets/ auf dem Server.
# Läuft lokal auf dem Mac, per Admin-SSH (nicht mit dem Deploy-Schlüssel).
#
#   scripts/push-secrets.sh             überträgt alle Werte, bricht ab, wenn einer fehlt
#   scripts/push-secrets.sh --generate  erzeugt fehlende Datenbank-Passwörter vorher und sichert sie nach Bitwarden
#
# Der Schlüsselbund ist die Quelle der Wahrheit. Nach einem Server-Neuaufbau genügt ein Aufruf.
# Nicht hier: der SSH-Schlüssel für Backups (entsteht auf dem Server, scripts/backup-ssh-key.sh).
# GitHub-Werte von Hand anlegen (fragt verdeckt nach dem Wert, landet nicht in der Shell-History):
#   scripts/schluesselbund.sh setzen hschaletzky-auth-github-client-id
#   scripts/schluesselbund.sh setzen hschaletzky-auth-github-client-secret
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/schluesselbund.sh

ADMIN_USER="${ADMIN_USER:-hannes}"
ADMIN_KEY="${ADMIN_KEY:-$HOME/.ssh/hschaletzky_com_hetzner}"
ZIEL=/opt/infra/secrets

# "Datei auf dem Server:Eintrag im Schlüsselbund:erzeugbar (ja, lang, base64 oder nein)" (macOS-Bash 3.2 kennt keine Hash-Arrays)
SECRETS=(
  pipeline_db_owner:hschaletzky-pipeline-db-owner:ja
  pipeline_db_app:hschaletzky-pipeline-db-app:ja
  pipeline_db_backup:hschaletzky-pipeline-db-backup:ja
  auth_db_owner:hschaletzky-auth-db-owner:ja
  auth_db_app:hschaletzky-auth-db-app:ja
  auth_secret:hschaletzky-auth-secret:ja
  auth_github_client_id:hschaletzky-auth-github-client-id:nein
  auth_github_client_secret:hschaletzky-auth-github-client-secret:nein
  plausible_secret_key_base:hschaletzky-plausible-secret-key-base:lang
  plausible_totp_vault_key:hschaletzky-plausible-totp-vault-key:base64
)

if [[ "${1:-}" == --generate ]]; then
  erzeugt=0
  for zeile in "${SECRETS[@]}"; do
    IFS=: read -r _ eintrag erzeugbar <<< "$zeile"
    if [[ "$erzeugbar" != nein ]] && ! im_schluesselbund "$eintrag"; then
      case "$erzeugbar" in
        # Plausible: SECRET_KEY_BASE braucht mindestens 64 Zeichen
        lang) wert="$(openssl rand -base64 96 | tr -dc 'A-Za-z0-9' | head -c 64)" ;;
        # Plausible: TOTP_VAULT_KEY sind genau 32 Byte, Base64-kodiert
        base64) wert="$(openssl rand -base64 32)" ;;
        # 32 Zeichen ohne Sonderzeichen: unproblematisch in URLs und Shells
        *) wert="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 32)" ;;
      esac
      in_schluesselbund "$eintrag" "$wert"
      echo "Erzeugt: $eintrag"
      erzeugt=1
    fi
  done
  # Neue Werte gleich nach Bitwarden kopieren, sonst gibt es sie nur im Schlüsselbund und auf dem Server
  if [[ "$erzeugt" == 1 ]]; then
    scripts/schluesselbund.sh sichern \
      || echo "Achtung: Die neuen Werte liegen nur im Schlüsselbund. Nachholen mit: scripts/schluesselbund.sh sichern" >&2
  fi
fi

host="${SERVER:-$(tofu/run.sh output -raw ipv4)}"
ssh_admin() { ssh -i "$ADMIN_KEY" "$ADMIN_USER@$host" "$@"; }

ssh_admin "sudo install -d -m 700 -o deploy -g deploy $ZIEL"

for zeile in "${SECRETS[@]}"; do
  IFS=: read -r datei eintrag _ <<< "$zeile"
  wert="$(aus_schluesselbund "$eintrag")"
  # 0444: Container lesen die Datei als eigener Nutzer (postgres, node). Geschützt ist sie
  # durch das Verzeichnis (0700, deploy), das nur in die Container eingehängt wird.
  printf %s "$wert" | ssh_admin "sudo sh -c 'umask 077; cat > $ZIEL/$datei.neu && chown deploy:deploy $ZIEL/$datei.neu && chmod 444 $ZIEL/$datei.neu && mv $ZIEL/$datei.neu $ZIEL/$datei'"
  echo "Übertragen: $datei"
done

echo "Fertig. Neue Werte wirken nach einem Deploy des betroffenen Dienstes (ssh deploy@$host deploy <dienst>)"
