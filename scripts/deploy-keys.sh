#!/usr/bin/env bash
# Deploy-Schlüssel pro Repo verwalten. Jedes Repo hat einen eigenen Schlüssel, der auf dem Server nur
# "deploy.sh <repo>" ausführen darf; was <repo> darf, steht in der Tabelle "rechte" in scripts/deploy.sh.
#
#   scripts/deploy-keys.sh neu <repo>[/<zweck>] [environment]
#       Erzeugt einen neuen Schlüssel (ersetzt einen vorhandenen), legt den öffentlichen Teil unter
#       tofu/keys/deploy/<name>.pub ab, überträgt authorized_keys auf den Server, testet den Schlüssel und
#       setzt ihn als Secret DEPLOY_SSH_KEY im Repo (mit environment: im GitHub-Environment).
#       <name> ist <repo> oder <repo>-<zweck>; so kann ein Repo mehrere Schlüssel mit getrennten Rechten haben
#       (z. B. hschaletzky-blog/preview als Repo-Secret, hschaletzky-blog im Environment production).
#       Der private Schlüssel existiert danach nur noch in GitHub. Bei Verdacht einfach neu erzeugen.
#
#   scripts/deploy-keys.sh installieren
#       Schreibt /home/deploy/.ssh/authorized_keys aus tofu/keys/deploy/*.pub neu (per Admin-SSH).
#
# Danach tofu/keys/deploy/ committen, damit ein Server-Neuaufbau (cloud-init) dieselben Schlüssel bekommt.
set -euo pipefail
cd "$(dirname "$0")/.."

OWNER=hannesschaletzky
. scripts/admin-ssh.sh
KEYS=tofu/keys/deploy
host="${SERVER:-$(tofu/run.sh output -raw ipv4)}"

authorized_keys() {
  for pub in "$KEYS"/*.pub; do
    name="$(basename "$pub" .pub)"
    echo "command=\"/opt/infra/scripts/deploy.sh $name\",restrict $(cat "$pub")"
  done
}

installieren() {
  # Erst vollständig schreiben, dann umbenennen: Ein abgebrochener Upload sperrt keine Deploys aus
  authorized_keys | ssh "${ADMIN_SSH[@]}" "$ADMIN_USER@$host" '
    set -e
    d=/home/deploy/.ssh
    sudo install -d -m 700 -o deploy -g deploy $d
    sudo tee $d/authorized_keys.neu >/dev/null
    sudo chown deploy:deploy $d/authorized_keys.neu
    sudo chmod 600 $d/authorized_keys.neu
    sudo mv $d/authorized_keys.neu $d/authorized_keys
    echo "authorized_keys: $(sudo grep -c . $d/authorized_keys) Schlüssel"'
}

case "${1:-}" in
  neu)
    angabe="${2:-}"
    env="${3:-}"
    if [[ ! "$angabe" =~ ^[A-Za-z0-9_.-]+(/[a-z0-9-]+)?$ ]]; then
      echo "Aufruf: $0 neu <repo>[/<zweck>] [environment]" >&2
      exit 1
    fi
    repo="${angabe%%/*}"
    name="${angabe/\//-}"
    gh repo view "$OWNER/$repo" --json name >/dev/null
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    ssh-keygen -q -t ed25519 -N "" -C "deploy@$name" -f "$tmp/key"
    install -d "$KEYS"
    cp "$tmp/key.pub" "$KEYS/$name.pub"
    installieren
    ssh -n -i "$tmp/key" -o IdentitiesOnly=yes "deploy@$host" rechte
    gh secret set DEPLOY_SSH_KEY -R "$OWNER/$repo" ${env:+--env "$env"} < "$tmp/key"
    echo "Fertig: $name. Ist der Schlüssel neu, Rechte in scripts/deploy.sh eintragen und DEPLOY_HOST/DEPLOY_KNOWN_HOSTS setzen (README)."
    ;;
  installieren)
    installieren
    ;;
  *)
    echo "Aufruf: $0 neu <repo>[/<zweck>] [environment] | installieren" >&2
    exit 1
    ;;
esac
