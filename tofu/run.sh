#!/usr/bin/env bash
# tofu mit Zugangsdaten aus dem Infra-Schlüsselbund, damit nichts im Klartext auf der Platte liegt.
# Der Schlüsselbund sperrt sich nach 5 Minuten, macOS fragt dann nach seinem Passwort.
#
# Einmalig ablegen (fragt verdeckt nach dem Wert, landet nicht in der Shell-History):
#   scripts/schluesselbund.sh setzen hschaletzky-hcloud-token
#   scripts/schluesselbund.sh setzen hschaletzky-tofu-passphrase
#   scripts/schluesselbund.sh setzen hschaletzky-uptimerobot-api-key
#
# Danach:  ./run.sh plan   ./run.sh apply   ./run.sh output -raw ipv4
set -euo pipefail
cd "$(dirname "$0")"
. ../scripts/schluesselbund.sh

HCLOUD_TOKEN="$(aus_schluesselbund hschaletzky-hcloud-token)"
TF_VAR_state_passphrase="$(aus_schluesselbund hschaletzky-tofu-passphrase)"
UPTIMEROBOT_API_KEY="$(aus_schluesselbund hschaletzky-uptimerobot-api-key)"
export HCLOUD_TOKEN TF_VAR_state_passphrase UPTIMEROBOT_API_KEY

exec tofu "$@"
