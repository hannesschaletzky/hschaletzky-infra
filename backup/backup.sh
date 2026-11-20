#!/usr/bin/env bash
# Tägliches Backup: Pipeline-Datenbank (pg_dump), SQLite-Volumes und Plausible (Postgres und
# ClickHouse), verschlüsselt mit age, per SFTP auf die Storage Box.
#
#   backup schedule   läuft dauerhaft, sichert täglich um BACKUP_HOUR_UTC (Standard im Container)
#   backup now        sichert sofort einmal (Test: docker compose run --rm backup now)
#
# Der Server kennt nur den öffentlichen age-Schlüssel: Er kann seine Backups schreiben, aber
# nicht lesen. Der private Schlüssel liegt nur im Passwortmanager und im Infra-Schlüsselbund am Mac.
# Klartext entsteht nur in /tmp, und das ist ein tmpfs (RAM).
set -euo pipefail

: "${BACKUP_TARGET:?z. B. u123-sub1@u123.your-storagebox.de}"
BACKUP_HOUR_UTC="${BACKUP_HOUR_UTC:-3}"
RETENTION_DAYS="${RETENTION_DAYS:-30}"
SOURCES=/sources
STATUS_FILE=/status/last-success
RECIPIENTS=/etc/backup/age-recipients.txt

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*"; }

sftp_batch() {
  sftp -P 23 -i "$key" -b - \
    -o UserKnownHostsFile=/etc/backup/known_hosts -o StrictHostKeyChecking=yes \
    -o BatchMode=yes -o ConnectTimeout=30 \
    "$BACKUP_TARGET"
}

run_backup() {
  local stamp
  stamp="$(date -u +%Y-%m-%dT%H%M%SZ)"
  work="$(mktemp -d)"
  # Der Schlüssel liegt bewusst nicht in $work: Hochgeladen wird alles aus $work.
  keydir="$(mktemp -d)"
  trap 'rm -rf "$work" "$keydir"' EXIT
  # SSH lehnt Schlüssel ab, die andere lesen dürfen; das Compose-Secret ist 0444.
  key="$keydir/ssh_key"
  install -m 600 /run/secrets/backup_ssh_key "$key"

  # Pipeline: Custom-Format (komprimiert, pg_restore kann einzelne Tabellen zurückholen)
  PGPASSWORD="$(cat /run/secrets/pipeline_db_backup)" \
    pg_dump --format=custom | age -R "$RECIPIENTS" -o "$work/pipeline.dump.age"

  # SQLite: .backup liefert einen konsistenten Stand, auch während die App schreibt
  local dir name db copy
  for dir in "$SOURCES"/*/; do
    name="$(basename "$dir")"
    for db in "$dir"*.db; do
      [[ -e "$db" ]] || continue
      copy="$work/$name-$(basename "$db")"
      sqlite3 "$db" ".backup '$copy'"
      [[ "$(sqlite3 "$copy" 'pragma quick_check')" == ok ]] || {
        log "FEHLER: Kopie von $name/$(basename "$db") ist beschädigt"
        return 1
      }
      age -R "$RECIPIENTS" -o "$copy.age" "$copy"
      rm "$copy"
    done
  done

  if [[ -n "${PLAUSIBLE_PGHOST:-}" ]]; then
    plausible_sichern
  fi

  # Erst unter .partial hochladen, dann umbenennen: Ein Abbruch hinterlässt nie einen
  # scheinbar vollständigen Stand.
  {
    echo "-mkdir daily"
    echo "mkdir daily/$stamp.partial"
    echo "put $work/*.age daily/$stamp.partial/"
    echo "rename daily/$stamp.partial daily/$stamp"
  } | sftp_batch >/dev/null

  date -u +%Y-%m-%dT%H:%M:%SZ >"$STATUS_FILE.tmp"
  mv "$STATUS_FILE.tmp" "$STATUS_FILE"
  local files=("$work"/*.age)
  log "Backup $stamp hochgeladen: ${#files[@]} Dateien, $(du -ch "${files[@]}" | tail -1 | cut -f1)"

  aufraeumen
}

# Plausible: Konten und Einstellungen (Postgres) und die Besuche (ClickHouse).
# ClickHouse wird pro Tabelle exportiert: Schema (SHOW CREATE), Daten im Format Native und die
# Zeilenzahl, dazu das Schema der Dictionaries, alles in einem tar.
plausible_sichern() {
  pg_dump -h "$PLAUSIBLE_PGHOST" -U postgres -d plausible --format=custom \
    | age -R "$RECIPIENTS" -o "$work/plausible.dump.age"

  local url="http://$PLAUSIBLE_CLICKHOUSE:8123/?database=plausible_events_db"
  local dir="$work/plausible-events" tabelle
  mkdir "$dir"
  ch() { wget -qO- --post-data "$1" "$url"; }
  ch "SELECT name FROM system.tables WHERE database = currentDatabase()
      AND (engine LIKE '%MergeTree' OR engine LIKE '%Log') ORDER BY name FORMAT TSV" >"$dir/tabellen.txt"
  [[ -s "$dir/tabellen.txt" ]] || { log "FEHLER: keine ClickHouse-Tabellen gefunden"; return 1; }
  while read -r tabelle; do
    # Zeilenzahl vor dem Export: Der Restore-Test vergleicht damit (neue Besuche können dazukommen)
    echo "$tabelle $(ch "SELECT count() FROM \`$tabelle\`")" >>"$dir/zeilen.txt"
    ch "SHOW CREATE TABLE \`$tabelle\` FORMAT TSVRaw" >"$dir/$tabelle.sql"
    ch "SELECT * FROM \`$tabelle\` FORMAT Native" | gzip >"$dir/$tabelle.native.gz"
  done <"$dir/tabellen.txt"
  # Dictionaries (Nachschlagetabellen): nur das Schema, ihre Daten stecken in den Quelltabellen.
  # events_v2 und sessions_v2 berechnen Spalten mit dictGet und lassen sich erst danach anlegen.
  ch "SELECT name FROM system.tables WHERE database = currentDatabase()
      AND engine = 'Dictionary' ORDER BY name FORMAT TSV" >"$dir/dictionaries.txt"
  while read -r tabelle; do
    ch "SHOW CREATE DICTIONARY \`$tabelle\` FORMAT TSVRaw" >"$dir/$tabelle.dict.sql"
  done <"$dir/dictionaries.txt"
  tar -C "$work" -cf - plausible-events | age -R "$RECIPIENTS" -o "$work/plausible-events.tar.age"
  rm -r "$dir"
}

# Löscht Stände, die älter als RETENTION_DAYS sind, und liegengebliebene .partial-Ordner.
# Die Snapshots der Storage Box sind davon unabhängig; die kann der Server nicht löschen.
aufraeumen() {
  local cutoff entry batch=""
  cutoff="$(date -u -d "@$(($(date +%s) - RETENTION_DAYS * 86400))" +%Y-%m-%dT%H%M%SZ)"
  while read -r entry; do
    entry="${entry##*/}"
    [[ "$entry" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{6}Z(\.partial)?$ ]] || continue
    if [[ "${entry%.partial}" < "$cutoff" || "$entry" == *.partial ]]; then
      batch+="-rm daily/$entry/*"$'\n'"rmdir daily/$entry"$'\n'
      log "Entferne alten Stand $entry"
    fi
  done < <(echo "ls -1 daily" | sftp_batch | grep -v '^sftp>')
  [[ -z "$batch" ]] || printf %s "$batch" | sftp_batch >/dev/null
}

sekunden_bis_zum_lauf() {
  local now target
  now="$(date +%s)"
  target=$((now - now % 86400 + BACKUP_HOUR_UTC * 3600))
  ((target > now)) || target=$((target + 86400))
  echo $((target - now))
}

case "${1:-schedule}" in
  now)
    run_backup
    ;;
  schedule)
    log "Backup-Dienst gestartet, täglich um ${BACKUP_HOUR_UTC}:00 UTC, Aufbewahrung ${RETENTION_DAYS} Tage"
    while true; do
      sleep "$(sekunden_bis_zum_lauf)"
      # Jeder Lauf als eigener Prozess: In "cmd || ..." würde Bash set -e sonst ignorieren.
      # Ein Fehler beendet den Dienst nicht. Der Zeitstempel bleibt dann alt, und /health
      # der Pipeline zeigt das wachsende Alter (backup.ageHours) für das Monitoring.
      "$0" now || log "FEHLER: Backup fehlgeschlagen"
    done
    ;;
  *)
    echo "Aufruf: backup [schedule|now]" >&2
    exit 1
    ;;
esac
