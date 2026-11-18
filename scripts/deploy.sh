#!/usr/bin/env bash
# Wird über einen SSH-"forced command" aufgerufen. Jedes Repo hat einen eigenen Deploy-Schlüssel, dessen
# Zeile in authorized_keys lautet:  command="/opt/infra/scripts/deploy.sh <repo>",restrict <schlüssel>
# Das Repo kommt also vom Server (Argument), der Befehl vom Aufrufer (SSH_ORIGINAL_COMMAND).
# Aufruf aus CI:  ssh deploy@server deploy <dienst>
#                 ssh deploy@server sync
#                 tar -czf - -C dist . | ssh deploy@server preview <slug>   (Blog-Preview, Repo hschaletzky-blog)
#                 ssh deploy@server preview-remove <slug>
#                 ssh deploy@server rechte          (zeigt, was dieser Schlüssel darf; ändert nichts)
set -euo pipefail
cd /opt/infra

repo="${1:-}"
read -r aktion dienst _ <<< "${SSH_ORIGINAL_COMMAND:-}"

# Was welcher Schlüssel darf. "aktion:dienst", "aktion:*" (beliebiger Slug) oder nur "aktion".
# Neues Repo: Schlüssel mit scripts/deploy-keys.sh anlegen und hier eintragen.
declare -A rechte=(
  [hschaletzky-infra]="sync"
  [hschaletzky]="deploy:hschaletzky"
  # Blog: zwei Schlüssel. Der Deploy-Schlüssel liegt im GitHub-Environment production (nur main), der
  # Preview-Schlüssel als Repo-Secret für alle Branches. Ein Branch-Workflow kommt so nie an "deploy blog".
  [hschaletzky-blog]="deploy:blog"
  [hschaletzky-blog-preview]="preview:* preview-remove:*"
  [fraktion_braeune]="deploy:fraktion-braeune"
  [tischlerei-mustermann]="deploy:tischlerei deploy:tischlerei-maengel"
  [sv-musterstadt]="deploy:sv-musterstadt"
  [physio-musterfrau]="deploy:physio-musterfrau"
  [quarantine_list]="deploy:quarantine"
  [focusgame]="deploy:focus"
  [hschaletzky-pipeline]="deploy:hschaletzky-pipeline"
  [hschaletzky-auth]="deploy:hschaletzky-auth"
)

if [[ -z "$repo" || -z "${rechte[$repo]+x}" ]]; then
  echo "Unbekannter Deploy-Schlüssel ('$repo')" >&2
  exit 1
fi

if [[ "$aktion" == rechte ]]; then
  echo "Schlüssel $repo darf: ${rechte[$repo]}"
  exit 0
fi

read -ra liste <<< "${rechte[$repo]}"
darf=nein
for recht in "${liste[@]}"; do
  if [[ "$recht" == "$aktion" && -z "${dienst:-}" || "$recht" == "$aktion:${dienst:-}" || "$recht" == "$aktion:*" ]]; then
    darf=ja
  fi
done
if [[ "$darf" != ja ]]; then
  echo "Schlüssel $repo darf '$aktion ${dienst:-}' nicht. Erlaubt: ${rechte[$repo]}" >&2
  exit 1
fi

# Deploys aus mehreren Repos nacheinander ausführen, sonst räumt "image prune" Schichten eines laufenden Pulls weg
exec 9>/tmp/hschaletzky-deploy.lock
flock -w 600 9

erlaubt=(hschaletzky tischlerei tischlerei-maengel sv-musterstadt physio-musterfrau quarantine focus hschaletzky-pipeline hschaletzky-auth blog fraktion-braeune)

# Blog-Previews: statische Dateien unter previews/<slug>, je eine Caddy-Site unter caddy/previews/<slug>.caddy
# (beides gitignored). Der Slug landet im Caddyfile und im Pfad, daher streng prüfen.
MAX_PREVIEWS=20
# Komprimiert und entpackt begrenzen: Ein kleines Archiv kann sonst zu Gigabytes aufgehen (Gzip-Bombe)
MAX_PREVIEW_BYTES=200000000
MAX_PREVIEW_ENTPACKT=300000000

slug_pruefen() {
  if [[ ! "${dienst:-}" =~ ^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?$ ]]; then
    echo "Ungültiger Preview-Name: '${dienst:-}' (erlaubt: a-z, 0-9, -, max. 40 Zeichen)" >&2
    exit 1
  fi
}

caddy_neu_laden() {
  docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile
}

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
  preview)
    slug_pruefen
    ziel="previews/$dienst"
    anzahl=$(find previews -mindepth 1 -maxdepth 1 -type d ! -name '.*' | wc -l)
    if [[ ! -d "$ziel" ]] && (( anzahl >= MAX_PREVIEWS )); then
      echo "Schon $anzahl Previews, maximal $MAX_PREVIEWS. Alte Branches löschen." >&2
      exit 1
    fi
    # Erst vollständig entpacken, dann austauschen: Die alte Fassung bleibt bis zum Schluss erreichbar
    neu=$(mktemp -d previews/.neu-XXXXXX)
    trap 'rm -rf "$neu" "$ziel.alt"' EXIT
    # GNU tar lehnt absolute Pfade und ".." ab; Symlinks braucht eine statische Seite nicht
    # Wird eine Grenze erreicht, bricht die Pipeline ab (pipefail) und der trap räumt auf
    if ! head -c "$MAX_PREVIEW_BYTES" | gzip -dc | head -c "$MAX_PREVIEW_ENTPACKT" \
      | tar -xf - -C "$neu" --no-same-owner --no-same-permissions; then
      echo "Archiv ungültig oder zu groß (max. $MAX_PREVIEW_BYTES Bytes komprimiert, $MAX_PREVIEW_ENTPACKT entpackt)" >&2
      exit 1
    fi
    find "$neu" -type l -delete
    if [[ ! -f "$neu/index.html" ]]; then
      echo "Kein index.html im Archiv" >&2
      exit 1
    fi
    chmod -R a+rX "$neu"
    rm -rf "$ziel.alt"
    if [[ -d "$ziel" ]]; then mv "$ziel" "$ziel.alt"; fi
    mv "$neu" "$ziel"
    if [[ ! -f "caddy/previews/$dienst.caddy" ]]; then
      printf '%s.preview.hschaletzky.com {\n\timport preview %s\n}\n' "$dienst" "$dienst" > "caddy/previews/$dienst.caddy"
      caddy_neu_laden
    fi
    echo "https://$dienst.preview.hschaletzky.com"
    exit 0
    ;;
  preview-remove)
    slug_pruefen
    rm -rf "previews/$dienst"
    if [[ -f "caddy/previews/$dienst.caddy" ]]; then
      rm "caddy/previews/$dienst.caddy"
      caddy_neu_laden
    fi
    echo "Preview $dienst entfernt"
    exit 0
    ;;
  sync)
    git pull --ff-only
    # Gibt es die Ordner beim Start von Caddy nicht, legt Docker sie als root an und deploy.sh kann nicht hineinschreiben
    mkdir -p previews caddy/previews
    # Der Backup-Dienst wird lokal gebaut, nicht gezogen
    docker compose pull --ignore-buildable
    docker compose build backup
    pipeline_migrieren
    auth_migrieren
    docker compose up -d --remove-orphans
    docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile
    ;;
  *)
    echo "Erlaubt: 'deploy <dienst>', 'sync', 'preview <slug>' oder 'preview-remove <slug>'" >&2
    exit 1
    ;;
esac

docker image prune -f >/dev/null
echo "Fertig: $aktion ${dienst:-}"
