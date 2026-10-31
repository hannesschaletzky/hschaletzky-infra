# hschaletzky-infra

Alles, was bei Hetzner läuft, als Code: Server, Firewall und DNS mit OpenTofu, darauf Docker Compose mit Caddy davor.

```
                    ┌──────────────── Hetzner (CX23, Ubuntu 24.04) ─────────────────┐
 Internet ──443──▶  │  caddy  ── TLS, HTTP/3, HSTS, Logs (14 Tage)                   │
                    │    ├── hschaletzky.com                       → hschaletzky:3000 │
                    │    └── tischlerei-mustermann.hschaletzky.com → tischlerei:80    │
                    └────────────────────────────────────────────────────────────────┘
            ▲ ghcr.io Images                     ▲ ssh deploy@server deploy <dienst>
            └──────────── GitHub Actions (pro Website-Repo) ──────┘
```

| Datei                    | Zweck                                                                          |
| ------------------------ | ------------------------------------------------------------------------------ |
| `tofu/server.tf`         | Server, feste IPv4/IPv6, Cloud-Firewall (22, 80, 443 TCP/UDP), Admin-SSH-Key     |
| `tofu/dns.tf`            | Zone `hschaletzky.com` inklusive Microsoft-365-Mail                             |
| `tofu/cloud-init.yaml`   | Einrichtung beim ersten Start: Updates, Docker, Benutzer, SSH-Härtung, fail2ban |
| `tofu/terraform.tfstate` | State, mit AES-GCM verschlüsselt                                               |
| `compose.yml`            | Alle Dienste. Eine neue Website = ein neuer Eintrag hier                        |
| `caddy/Caddyfile`        | Domains → Container, Zertifikate automatisch via Let's Encrypt                  |
| `scripts/deploy.sh`      | Einziger Befehl, den GitHub Actions auf dem Server ausführen darf               |

## Prinzip

- **Der Server ist austauschbar.** Alles steckt in diesem Repo und in den Images. Die IP-Adressen sind eigene
  Ressourcen und bleiben bei einem Neuaufbau (`tofu apply -replace=hcloud_server.web`) erhalten.
- **Jede Website ist ihr eigenes Repo** mit Dockerfile und Workflow. Der Workflow baut ein Image nach `ghcr.io`
  und ruft danach `ssh deploy@server deploy <dienst>` auf.
- **Der Deploy-Schlüssel kann nichts anderes.** In `authorized_keys` ist er per `command=` und `restrict` auf
  `deploy.sh` festgelegt. Damit gibt es keine Shell, kein Forwarding und nur Dienste aus der Allowlist.
- **Änderungen an Compose oder Caddy** werden per `sync.yml` ausgerollt: `git pull`, `up -d`, `caddy reload`.
- **Änderungen an `tofu/`** laufen lokal mit `tofu/run.sh apply`. Danach den State committen.

## Ersteinrichtung

### 1. Zugänge

- Hetzner Console → *Sicherheit → API-Tokens* → Token mit **Lesen & Schreiben** erstellen.
- Eine lange Passphrase für den State erzeugen (mind. 16 Zeichen). Beides kommt in den Passwortmanager.

### 2. Schlüssel

```sh
ssh-keygen -t ed25519 -f ~/.ssh/hschaletzky_com_hetzner -C "admin@hschaletzky-infra"         # mit Passphrase
ssh-keygen -t ed25519 -f ~/.ssh/hschaletzky_com_deploy  -C "github-actions@hschaletzky-infra" -N ""
cp ~/.ssh/hschaletzky_com_hetzner.pub tofu/keys/admin.pub
cp ~/.ssh/hschaletzky_com_deploy.pub  tofu/keys/deploy.pub
```

### 3. Anlegen

Token und Passphrase einmalig in den macOS-Schlüsselbund legen. `-w` ohne Wert fragt danach, so landet nichts in der
Shell-History:

```sh
security add-generic-password -a "$USER" -s hschaletzky-hcloud-token -w
security add-generic-password -a "$USER" -s hschaletzky-tofu-passphrase -w
```

`tofu/run.sh` liest beide beim Aufruf aus und reicht alle Argumente an `tofu` weiter:

```sh
tofu/run.sh init
tofu/run.sh apply
git add . && git commit -m "Infrastruktur angelegt" && git push
```

cloud-init braucht danach etwa drei Minuten. Login: `ssh -i ~/.ssh/hschaletzky_com_hetzner hannes@<ipv4>`.

### 4. Nameserver bei Strato

Die Ausgabe `nameserver` bei Strato als externe Nameserver für `hschaletzky.com` eintragen. Die Zone enthält
bereits alle bisherigen Einträge (Mail, SPF, DMARC, Autodiscover, Google-Verifizierung); `hschaletzky.com` zeigt
weiterhin auf Vercel. Prüfen: `dig +short NS hschaletzky.com` und `dig +short MX hschaletzky.com`.

### 5. GitHub

In **jedem** Website-Repo und in diesem Repo: Environment `production` mit den Secrets

| Secret               | Inhalt                                          |
| -------------------- | ----------------------------------------------- |
| `DEPLOY_HOST`        | `tofu output -raw ipv4`                         |
| `DEPLOY_SSH_KEY`     | Inhalt von `~/.ssh/hschaletzky_com_deploy` (privat) |
| `DEPLOY_KNOWN_HOSTS` | Ausgabe von `ssh-keyscan -t ed25519 <ipv4>`     |

Pakete auf ghcr.io sind zunächst privat. Entweder unter *Package settings → Change visibility* auf **public** stellen
(empfohlen, die Images enthalten nichts Geheimes) oder auf dem Server einmal anmelden:
`echo <PAT mit read:packages> | sudo -u deploy docker login ghcr.io -u hannesschaletzky --password-stdin`.

### 6. hschaletzky.com umziehen

Sobald der `hschaletzky`-Container läuft (`docker compose ps`), in `tofu/terraform.tfvars`
`hschaletzky_auf_server = true` setzen und `tofu apply`. Damit zeigen A und AAAA auf den Server.

## Alltag

```sh
# Status und Logs
ssh hannes@<server> 'cd /opt/infra && docker compose ps'
ssh hannes@<server> 'cd /opt/infra && docker compose logs -f --tail=100 tischlerei'

# Rollback auf einen früheren Commit (jedes Image ist zusätzlich mit dem Git-SHA getaggt)
ssh hannes@<server> 'cd /opt/infra && TISCHLEREI_TAG=<sha> docker compose up -d tischlerei'
```

## Neue Website hinzufügen

1. Dockerfile und `deploy.yml` in das neue Repo (Vorlage: `tischlerei-mustermann`), der letzte Schritt lautet `deploy <name>`
2. Dienst in `compose.yml`, Domain in `caddy/Caddyfile`, Name in die Allowlist von `scripts/deploy.sh`
3. DNS-Eintrag in `tofu/dns.tf`, `tofu/run.sh apply`, State committen, pushen, fertig
