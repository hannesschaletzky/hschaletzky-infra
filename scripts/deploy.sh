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
erlaubt=(hschaletzky tischlerei tischlerei-maengel sv-musterstadt physio-musterfrau)

case "$aktion" in
  deploy)
    if [[ ! " ${erlaubt[*]} " == *" ${dienst:-} "* ]]; then
      echo "Unbekannter Dienst: '${dienst:-}'. Erlaubt: ${erlaubt[*]}" >&2
      exit 1
    fi
    docker compose pull "$dienst"
    docker compose up -d --no-deps "$dienst"
    ;;
  sync)
    git pull --ff-only
    docker compose pull
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
