#!/usr/bin/env bash
# Backups von der Storage Box holen und entschlüsseln. Läuft lokal auf dem Mac, denn nur hier
# liegt der private age-Schlüssel (Schlüsselbund: hschaletzky-backup-age).
#
#   scripts/backup-restore.sh list            vorhandene Stände
#   scripts/backup-restore.sh fetch [STAND]   holt und entschlüsselt einen Stand (Standard: neuester)
#   scripts/backup-restore.sh test  [STAND]   Restore-Test: spielt den Dump in ein Wegwerf-Postgres
#                                             ein, prüft die SQLite-Dateien und räumt alles wieder ab
#
# Snapshots älterer Tage: auf der Box unter .zfs/snapshot/<name>/backups/daily/ (nur lesen).
set -euo pipefail
cd "$(dirname "$0")/.."

ADMIN_KEY="${ADMIN_KEY:-$HOME/.ssh/hschaletzky_com_hetzner}"
AGE_EINTRAG=hschaletzky-backup-age

box="$(tofu/run.sh output -raw storage_box_host)"
box_user="$(tofu/run.sh output -raw storage_box_user)"

sftp_batch() {
  sftp -P 23 -i "$ADMIN_KEY" -b - -o StrictHostKeyChecking=yes \
    -o UserKnownHostsFile=backup/known_hosts "$box_user@$box"
}

staende() {
  echo "ls -1 backups/daily" | sftp_batch | grep -v '^sftp>' | sed 's#.*/##' \
    | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{6}Z$' | sort
}

age_schluessel() {
  security find-generic-password -a "$USER" -s "$AGE_EINTRAG" -w 2>/dev/null || {
    echo "Kein Eintrag '$AGE_EINTRAG' im Schlüsselbund (privater age-Schlüssel, siehe Passwortmanager)." >&2
    exit 1
  }
}

# holen STAND ZIEL: lädt alle Dateien und entschlüsselt sie nach ZIEL
holen() {
  local stand="$1" ziel="$2" datei
  mkdir -p "$ziel/verschluesselt"
  echo "get backups/daily/$stand/* $ziel/verschluesselt/" | sftp_batch >/dev/null
  for datei in "$ziel"/verschluesselt/*.age; do
    age -d -i <(age_schluessel) -o "$ziel/$(basename "${datei%.age}")" "$datei"
  done
  rm -r "$ziel/verschluesselt"
}

stand_waehlen() {
  local stand="${1:-$(staende | tail -1)}"
  [[ -n "$stand" ]] || { echo "Keine Backups gefunden." >&2; exit 1; }
  echo "$stand"
}

case "${1:-}" in
  list)
    staende
    ;;
  fetch)
    stand="$(stand_waehlen "${2:-}")"
    ziel="$HOME/hschaletzky-restore/$stand"
    holen "$stand" "$ziel"
    echo "Entschlüsselt nach $ziel (echte Daten: nach Gebrauch löschen)"
    ls -lh "$ziel"
    ;;
  test)
    stand="$(stand_waehlen "${2:-}")"
    ziel="$(mktemp -d)"
    container="restore-test-$$"
    trap 'docker rm -f "$container" >/dev/null 2>&1 || true; rm -rf "$ziel"' EXIT
    holen "$stand" "$ziel"

    image="$(sed -n 's/^ *image: *\(postgres:[^ ]*\)$/\1/p' compose.yml | head -1)"
    docker run -d --name "$container" -e POSTGRES_PASSWORD=restore-test -e POSTGRES_DB=pipeline \
      "$image" >/dev/null
    until docker exec "$container" pg_isready -U postgres -d pipeline >/dev/null 2>&1; do sleep 1; done
    sleep 2 # Das Image startet Postgres nach der Ersteinrichtung einmal neu
    until docker exec "$container" pg_isready -U postgres -d pipeline >/dev/null 2>&1; do sleep 1; done
    docker cp "$ziel/pipeline.dump" "$container:/tmp/pipeline.dump"
    docker exec "$container" pg_restore -U postgres -d pipeline --no-owner --no-acl --exit-on-error /tmp/pipeline.dump

    echo "== Pipeline ($stand): Zeilen je Tabelle"
    # analyze, damit die Zeilenzahlen in pg_stat_user_tables stimmen
    docker exec "$container" psql -U postgres -d pipeline -Atc "analyze" >/dev/null
    docker exec "$container" psql -U postgres -d pipeline -Atc "
      select format('%-24s %s', relname, n_live_tup) from pg_stat_user_tables order by relname"
    echo "== Migrationen: $(docker exec "$container" psql -U postgres -d pipeline -Atc \
      'select count(*) from drizzle.__drizzle_migrations')"

    echo "== SQLite"
    for db in "$ziel"/*.db; do
      [[ -e "$db" ]] || continue
      echo "$(basename "$db"): $(sqlite3 "$db" 'pragma integrity_check'), Tabellen: $(sqlite3 "$db" \
        "select count(*) from sqlite_master where type = 'table'")"
    done
    echo "Restore-Test erfolgreich. Wegwerf-Container und entschlüsselte Dateien werden gelöscht."
    ;;
  *)
    sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
