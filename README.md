# hschaletzky-infra

Alles, was auf dem Hetzner-Server läuft. Ein Server, Docker Compose, Caddy davor.

```
                    ┌──────────────── Hetzner (Ubuntu 24.04) ────────────────┐
 Internet ──443──▶  │  caddy  ── TLS, HTTP/3, HSTS, Logs (14 Tage)            │
                    │    ├── hschaletzky.com                 → hschaletzky:3000 │
                    │    └── tischlerei-mustermann.hschaletzky.com → tischlerei:80 │
                    └────────────────────────────────────────────────────────┘
            ▲ ghcr.io Images                     ▲ ssh deploy@server deploy <dienst>
            └──────────── GitHub Actions (pro Website-Repo) ──────┘
```

| Datei                 | Zweck                                                         |
| --------------------- | ------------------------------------------------------------- |
| `compose.yml`         | Alle Dienste. Eine neue Website = ein neuer Eintrag hier       |
| `caddy/Caddyfile`     | Domains → Container, Zertifikate automatisch via Let's Encrypt |
| `scripts/bootstrap.sh`| Einmalige Server-Einrichtung (Updates, Docker, Firewall, SSH-Härtung, Benutzer) |
| `scripts/deploy.sh`   | Einziger Befehl, den GitHub Actions auf dem Server ausführen darf |

## Prinzip

- **Jede Website ist ihr eigenes Repo** mit Dockerfile und Workflow. Der Workflow baut ein Image nach `ghcr.io`
  und ruft danach `ssh deploy@server deploy <dienst>` auf.
- **Der Deploy-Schlüssel kann nichts anderes.** In `authorized_keys` ist er per `command=` und `restrict` auf
  `deploy.sh` festgelegt. Damit gibt es keine Shell, kein Forwarding und nur Dienste aus der Allowlist.
- **Änderungen an diesem Repo** (Compose, Caddy) werden per `sync.yml` ausgerollt: `git pull`, `up -d`, `caddy reload`.

## Ersteinrichtung

### 1. Server

Ein CX22 (x86) oder CAX11 (ARM) mit Ubuntu 24.04 reicht für mehrere Websites. Die Images werden für beide Architekturen gebaut.

### 2. Schlüssel erzeugen (lokal)

```sh
ssh-keygen -t ed25519 -f ~/.ssh/hetzner_deploy -C "github-actions-deploy" -N ""
```

### 3. Bootstrap (einmalig als root)

Dieses Repo muss dafür öffentlich sein (es enthält keine Geheimnisse) oder vorher auf den Server kopiert werden.

```sh
scp scripts/bootstrap.sh root@<server>:
ssh root@<server> bash bootstrap.sh "$(cat ~/.ssh/id_ed25519.pub)" "$(cat ~/.ssh/hetzner_deploy.pub)"
```

Danach in einem **zweiten Terminal** `ssh hannes@<server>` testen, bevor die Root-Sitzung geschlossen wird.

> Schon ein Server mit anderen Diensten im Einsatz? Dann das Skript vorher lesen und nur die passenden Abschnitte ausführen.

### 4. DNS

| Name                                   | Typ        | Wert                |
| -------------------------------------- | ---------- | ------------------- |
| `hschaletzky.com`                      | A / AAAA   | Server-IPv4 / IPv6  |
| `www.hschaletzky.com`                  | CNAME      | `hschaletzky.com`   |
| `tischlerei-mustermann.hschaletzky.com`| A / AAAA   | Server-IPv4 / IPv6  |

### 5. GitHub

In **jedem** Website-Repo und in diesem Repo: Environment `production` mit den Secrets

| Secret               | Inhalt                                             |
| -------------------- | -------------------------------------------------- |
| `DEPLOY_HOST`        | IP oder Hostname des Servers                        |
| `DEPLOY_SSH_KEY`     | Inhalt von `~/.ssh/hetzner_deploy` (privat)         |
| `DEPLOY_KNOWN_HOSTS` | Ausgabe von `ssh-keyscan -t ed25519 <server>`       |

Pakete auf ghcr.io sind zunächst privat. Entweder unter *Package settings → Change visibility* auf **public** stellen
(empfohlen, die Images enthalten nichts Geheimes) oder auf dem Server einmal anmelden:
`echo <PAT mit read:packages> | docker login ghcr.io -u hannesschaletzky --password-stdin` (als Benutzer `deploy`).

### 6. Erster Start

Beide Website-Repos einmal pushen (oder Workflow manuell starten), damit die Images existieren. Danach:

```sh
ssh hannes@<server>
cd /opt/infra && sudo -u deploy docker compose up -d
```

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
3. DNS-Eintrag setzen, pushen, fertig
