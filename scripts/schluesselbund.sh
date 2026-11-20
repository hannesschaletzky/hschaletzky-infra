#!/usr/bin/env bash
# Eigener macOS-Schlüsselbund für alle Infra-Secrets (Hetzner-Token, State-Passphrase, Datenbank-
# Passwörter, age-Schlüssel). Er hat ein eigenes Passwort und sperrt sich nach 5 Minuten ohne Zugriff
# und beim Ruhezustand. Der Anmelde-Schlüsselbund ist dagegen offen, solange man angemeldet ist: Jedes
# Programm unter dem eigenen Nutzer könnte die Einträge dort ohne Rückfrage lesen.
#
#   scripts/schluesselbund.sh einrichten        legt den Schlüsselbund an (fragt nach einem neuen Passwort)
#   scripts/schluesselbund.sh setzen <eintrag>  legt einen Wert an oder ersetzt ihn (fragt verdeckt danach)
#   scripts/schluesselbund.sh liste             zeigt die Namen der Einträge, keine Werte
#   scripts/schluesselbund.sh sperren           sperrt sofort
#
# Ist der Schlüsselbund gesperrt, fragt macOS beim nächsten Zugriff in einem Fenster nach dem Passwort.
# Die anderen Skripte binden diese Datei ein (". scripts/schluesselbund.sh") und nutzen
# aus_schluesselbund und in_schluesselbund.

SCHLUESSELBUND="${SCHLUESSELBUND:-$HOME/Library/Keychains/hschaletzky-infra.keychain-db}"
SCHLUESSELBUND_SPERRE_SEKUNDEN=300

# _wert_lesen EINTRAG SCHLÜSSELBUND: gibt den Wert aus, Status 1, wenn es den Eintrag nicht gibt.
# Mit -g statt -w, weil nur so eindeutig ist, ob security den Wert als Hex ausgibt (bei Zeichen
# außerhalb von ASCII: ä, ß, €) oder im Klartext.
_wert_lesen() {
  local zeile
  zeile="$(security find-generic-password -a "$USER" -s "$1" -g "$2" 2>&1 >/dev/null | grep '^password: ')" || return 1
  zeile="${zeile#password: }"
  if [[ "$zeile" == 0x* ]]; then
    zeile="${zeile#0x}"
    printf %s "${zeile%% *}" | xxd -r -p
  else
    zeile="${zeile#\"}"
    printf %s "${zeile%\"}"
  fi
}

# _wert_schreiben EINTRAG WERT SCHLÜSSELBUND: legt an oder ersetzt. Der Wert geht als Hex über die
# Standardeingabe an security, so steht er nie in der Prozessliste und Sonderzeichen stören nicht.
_wert_schreiben() {
  local hex
  hex="$(printf %s "$2" | xxd -p | tr -d '\n')"
  printf 'add-generic-password -U -a "%s" -s "%s" -X %s "%s"\n' "$USER" "$1" "$hex" "$3" \
    | security -i >/dev/null
}

_schluesselbund_pruefen() {
  [[ -f "$SCHLUESSELBUND" ]] || {
    echo "Der Schlüsselbund $SCHLUESSELBUND fehlt. Anlegen mit: scripts/schluesselbund.sh einrichten" >&2
    return 1
  }
}

# aus_schluesselbund EINTRAG: gibt den Wert aus. Fehlt der Eintrag, kommt ein Hinweis und Status 1.
aus_schluesselbund() {
  _schluesselbund_pruefen || return 1
  _wert_lesen "$1" "$SCHLUESSELBUND" || {
    echo "Kein Eintrag '$1' im Schlüsselbund. Anlegen mit: scripts/schluesselbund.sh setzen $1" >&2
    return 1
  }
}

# im_schluesselbund EINTRAG: Status 0, wenn es den Eintrag gibt. Gibt nichts aus.
im_schluesselbund() {
  _schluesselbund_pruefen || return 1
  _wert_lesen "$1" "$SCHLUESSELBUND" >/dev/null
}

# in_schluesselbund EINTRAG WERT: legt den Eintrag an oder ersetzt ihn.
in_schluesselbund() {
  _schluesselbund_pruefen || return 1
  _wert_schreiben "$1" "$2" "$SCHLUESSELBUND"
}

_einrichten() {
  if [[ -f "$SCHLUESSELBUND" ]]; then
    echo "Den Schlüsselbund gibt es schon, ich setze nur die Sperre neu."
  else
    echo "Neues Passwort für den Infra-Schlüsselbund wählen: ein anderes als das Anmeldepasswort."
    echo "Vorher in Bitwarden speichern. Ohne das Passwort sind die Einträge nicht mehr lesbar."
    security create-keychain "$SCHLUESSELBUND"
  fi
  security set-keychain-settings -l -t "$SCHLUESSELBUND_SPERRE_SEKUNDEN" "$SCHLUESSELBUND"
  echo "Fertig: $SCHLUESSELBUND sperrt sich nach $SCHLUESSELBUND_SPERRE_SEKUNDEN Sekunden und beim Ruhezustand."
}

# Namen aller Einträge eines Schlüsselbunds, ohne Werte
_namen() {
  security dump-keychain "$1" | sed -n 's/^ *"svce"<blob>="\(.*\)"$/\1/p' | sort -u
}

_setzen() {
  [[ -n "${1:-}" ]] || { echo "Aufruf: scripts/schluesselbund.sh setzen <eintrag>" >&2; exit 1; }
  local wert
  read -rsp "Wert für '$1': " wert
  echo
  [[ -n "$wert" ]] || { echo "Leerer Wert, nichts geändert." >&2; exit 1; }
  in_schluesselbund "$1" "$wert"
  echo "Gespeichert: $1"
}

# Nur beim direkten Aufruf, nicht beim Einbinden mit "."
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  case "${1:-}" in
    einrichten) _einrichten ;;
    setzen) _setzen "${2:-}" ;;
    liste) _schluesselbund_pruefen && _namen "$SCHLUESSELBUND" ;;
    sperren) security lock-keychain "$SCHLUESSELBUND" ;;
    *) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//' ;;
  esac
fi
