#!/usr/bin/env bash
# Wird über einen SSH-"forced command" aufgerufen: Der Deploy-Schlüssel kann nur dieses Skript ausführen.
# Aufruf aus CI:  ssh deploy@server deploy <dienst>
#                 ssh deploy@server sync
set -euo pipefail
cd /opt/infra

# Deploys aus mehreren Repos nacheinander ausführen, sonst räumt "image prune" Schichten eines laufenden Pulls weg
exec 9>/tmp/hschaletzky-deploy.lock
flock -w 600 9

read -r aktion dienst _ <<< "${SSH_ORIGINAL_COMMAND:-$*}"
erlaubt=(hschaletzky tischlerei tischlerei-maengel sv-musterstadt physio-musterfrau quarantine focus hschaletzky-pipeline hschaletzky-auth)

# Datenbank-Migrationen der Pipeline (Owner-Rolle, idempotent). Vor der App ausführen, damit
# neuer Code nie auf ein altes Schema trifft.
pipeline_migrieren() {
  docker compose up -d --wait postgres
  docker compose run --rm pipeline-migrate
}

# Dasselbe für hschaletzky-auth (eigene Datenbank)
auth_migrieren() {
  docker compose up -d --wait auth-postgres
  docker compose run --rm auth-migrate
}

case "$aktion" in
  deploy)
    if [[ ! " ${erlaubt[*]} " == *" ${dienst:-} "* ]]; then
      echo "Unbekannter Dienst: '${dienst:-}'. Erlaubt: ${erlaubt[*]}" >&2
      exit 1
    fi
    docker compose pull "$dienst"
    if [[ "$dienst" == hschaletzky-pipeline ]]; then
      pipeline_migrieren
    fi
    if [[ "$dienst" == hschaletzky-auth ]]; then
      auth_migrieren
    fi
    docker compose up -d --no-deps "$dienst"
    ;;
  sync)
    git pull --ff-only
    # Der Backup-Dienst wird lokal gebaut, nicht gezogen
    docker compose pull --ignore-buildable
    docker compose build backup
    pipeline_migrieren
    auth_migrieren
    docker compose up -d --remove-orphans
    docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile
    ;;
  *)
    echo "Erlaubt: 'deploy <dienst>' oder 'sync'" >&2
    exit 1
    ;;
esac

docker image prune -f >/dev/null
echo "Fertig: $aktion ${dienst:-}"
