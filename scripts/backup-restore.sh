#!/usr/bin/env bash
# Backups von der Storage Box holen und entschlüsseln. Läuft lokal auf dem Mac, denn nur hier
# liegt der private age-Schlüssel (Schlüsselbund: hschaletzky-backup-age).
#
#   scripts/backup-restore.sh list            vorhandene Stände
#   scripts/backup-restore.sh fetch [STAND]   holt und entschlüsselt einen Stand (Standard: neuester)
#   scripts/backup-restore.sh test  [STAND]   Restore-Test: spielt Pipeline und Plausible in Wegwerf-
#                                             Container (Postgres, ClickHouse) ein, prüft die
#                                             SQLite-Dateien und räumt alles wieder ab
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

# warten CONTAINER BEFEHL…: wiederholt BEFEHL im Container, bis er klappt. Bricht ab, wenn der
# Container nicht mehr läuft oder nach 120 Sekunden, statt endlos zu warten.
warten() {
  local container="$1" i
  shift
  for i in $(seq 120); do
    docker exec "$container" "$@" >/dev/null 2>&1 && return 0
    if [[ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null)" != true ]]; then
      echo "FEHLER: Container $container läuft nicht mehr:" >&2
      docker logs --tail 5 "$container" >&2 || true
      return 1
    fi
    sleep 1
  done
  echo "FEHLER: $container nach 120 s nicht bereit" >&2
  return 1
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
    clickhouse="restore-test-ch-$$"
    trap 'docker rm -f "$container" "$clickhouse" >/dev/null 2>&1 || true; rm -rf "$ziel"' EXIT
    holen "$stand" "$ziel"

    image="$(sed -n 's/^ *image: *\(postgres:[^ ]*\)$/\1/p' compose.yml | head -1)"
    docker run -d --name "$container" -e POSTGRES_PASSWORD=restore-test -e POSTGRES_DB=pipeline \
      "$image" >/dev/null
    warten "$container" pg_isready -U postgres -d pipeline
    sleep 2 # Das Image startet Postgres nach der Ersteinrichtung einmal neu
    warten "$container" pg_isready -U postgres -d pipeline
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
    # Plausible: in Ständen vor dem 19.11.2026 noch nicht enthalten
    if [[ -f "$ziel/plausible.dump" ]]; then
      echo "== Plausible Postgres (Konten, Seiten)"
      # Gleicher Wegwerf-Postgres: pg_restore muss mindestens so neu sein wie das pg_dump im Backup-Image
      docker exec "$container" createdb -U postgres plausible
      docker cp "$ziel/plausible.dump" "$container:/tmp/plausible.dump"
      docker exec "$container" pg_restore -U postgres -d plausible --no-owner --no-acl --exit-on-error \
        /tmp/plausible.dump
      docker exec "$container" psql -U postgres -d plausible -Atc "
        select format('%-24s %s', t, n) from (
          select 'users' t, count(*) n from users union all
          select 'sites', count(*) from sites union all
          select 'goals', count(*) from goals) x"

      echo "== Plausible ClickHouse (Besuche): Zeilen im Backup → wiederhergestellt"
      mkdir "$ziel/ch"
      tar -C "$ziel/ch" -xf "$ziel/plausible-events.tar"
      ch_image="$(sed -n 's/^ *image: *\(clickhouse\/[^ ]*\)$/\1/p' compose.yml | head -1)"
      docker run -d --name "$clickhouse" -e CLICKHOUSE_SKIP_USER_SETUP=1 "$ch_image" >/dev/null
      warten "$clickhouse" clickhouse-client -q "SELECT 1"
      docker exec "$clickhouse" clickhouse-client -q "CREATE DATABASE plausible_events_db"
      pe="$ziel/ch/plausible-events"
      anlegen() { docker exec -i "$clickhouse" clickhouse-client --database plausible_events_db <"$1"; }
      # Reihenfolge: Tabellen ohne dictGet, dann die Dictionaries (lesen aus diesen Tabellen),
      # dann die Tabellen, deren Spalten dictGet verwenden
      while read -r tabelle _; do
        if ! grep -q dictGet "$pe/$tabelle.sql"; then anlegen "$pe/$tabelle.sql"; fi
      done <"$pe/zeilen.txt"
      while read -r tabelle; do anlegen "$pe/$tabelle.dict.sql"; done <"$pe/dictionaries.txt"
      while read -r tabelle _; do
        if grep -q dictGet "$pe/$tabelle.sql"; then anlegen "$pe/$tabelle.sql"; fi
      done <"$pe/zeilen.txt"

      leer=0
      while read -r tabelle erwartet; do
        # Leere Tabellen: ClickHouse lehnt ein INSERT ohne Daten ab
        if [[ -n "$(gunzip -c "$ziel/ch/plausible-events/$tabelle.native.gz" | head -c 1)" ]]; then
          gunzip -c "$ziel/ch/plausible-events/$tabelle.native.gz" \
            | docker exec -i "$clickhouse" clickhouse-client \
              -q "INSERT INTO plausible_events_db.\`$tabelle\` FORMAT Native"
        fi
        ist="$(docker exec "$clickhouse" clickhouse-client \
          -q "SELECT count() FROM plausible_events_db.\`$tabelle\`")"
        # Exakte Gleichheit ist nicht garantiert (neue Besuche, Collapsing-Merges), leer darf nichts sein
        if (( erwartet > 0 && ist == 0 )); then leer=$((leer + 1)); markierung="  ← LEER"; else markierung=""; fi
        printf '%-42s %8s → %s%s\n' "$tabelle" "$erwartet" "$ist" "$markierung"
      done <"$ziel/ch/plausible-events/zeilen.txt"
      (( leer == 0 )) || { echo "FEHLER: $leer Tabelle(n) ohne Daten wiederhergestellt" >&2; exit 1; }
    else
      echo "== Plausible: in diesem Stand nicht enthalten"
    fi

    echo "Restore-Test erfolgreich. Wegwerf-Container und entschlüsselte Dateien werden gelöscht."
    ;;
  *)
    sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
