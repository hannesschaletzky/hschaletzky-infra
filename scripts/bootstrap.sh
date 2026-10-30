#!/usr/bin/env bash
# Einmalige Einrichtung eines frischen Hetzner-Servers (Ubuntu 24.04). Als root ausführen:
#   curl -fsSL https://raw.githubusercontent.com/hannesschaletzky/hschaletzky-infra/main/scripts/bootstrap.sh | bash -s -- "<dein öffentlicher SSH-Schlüssel>" "<öffentlicher Deploy-Schlüssel>"
# oder nach dem Kopieren auf den Server:  bash bootstrap.sh "<admin-key>" "<deploy-key>"
set -euo pipefail

ADMIN_KEY="${1:?Öffentlicher SSH-Schlüssel für den Admin-Benutzer fehlt}"
DEPLOY_KEY="${2:?Öffentlicher SSH-Schlüssel für GitHub Actions fehlt}"
ADMIN_USER="hannes"
REPO="https://github.com/hannesschaletzky/hschaletzky-infra.git"

export DEBIAN_FRONTEND=noninteractive

echo "==> System aktualisieren"
apt-get update -q
apt-get upgrade -yq
apt-get install -yq ca-certificates curl git ufw fail2ban unattended-upgrades

echo "==> Automatische Sicherheitsupdates"
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'CONF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
CONF
cat > /etc/apt/apt.conf.d/52unattended-upgrades-local <<'CONF'
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:30";
CONF

echo "==> Docker installieren"
if ! command -v docker >/dev/null; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -q
  apt-get install -yq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
cat > /etc/docker/daemon.json <<'CONF'
{ "log-driver": "local", "log-opts": { "max-size": "10m", "max-file": "3" } }
CONF
systemctl restart docker

echo "==> Benutzer anlegen"
id "$ADMIN_USER" >/dev/null 2>&1 || adduser --disabled-password --gecos "" "$ADMIN_USER"
usermod -aG sudo,docker "$ADMIN_USER"
echo "$ADMIN_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-$ADMIN_USER"
install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_USER" "/home/$ADMIN_USER/.ssh"
echo "$ADMIN_KEY" > "/home/$ADMIN_USER/.ssh/authorized_keys"
chown "$ADMIN_USER:$ADMIN_USER" "/home/$ADMIN_USER/.ssh/authorized_keys"
chmod 600 "/home/$ADMIN_USER/.ssh/authorized_keys"

id deploy >/dev/null 2>&1 || adduser --disabled-password --gecos "" deploy
usermod -aG docker deploy
install -d -m 700 -o deploy -g deploy /home/deploy/.ssh
# Der Deploy-Schlüssel darf ausschließlich deploy.sh ausführen, keine Shell, kein Port-Forwarding.
echo "command=\"/opt/infra/scripts/deploy.sh\",restrict $DEPLOY_KEY" > /home/deploy/.ssh/authorized_keys
chown deploy:deploy /home/deploy/.ssh/authorized_keys
chmod 600 /home/deploy/.ssh/authorized_keys

echo "==> infra-Repo nach /opt/infra"
if [ ! -d /opt/infra/.git ]; then
  git clone "$REPO" /opt/infra
fi
chown -R deploy:deploy /opt/infra
git config --system --add safe.directory /opt/infra

echo "==> SSH absichern"
cat > /etc/ssh/sshd_config.d/10-hardening.conf <<'CONF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
X11Forwarding no
MaxAuthTries 3
CONF
sshd -t && systemctl reload ssh

echo "==> Firewall"
ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 443/udp
ufw --force enable

echo "==> fail2ban"
cat > /etc/fail2ban/jail.d/sshd.local <<'CONF'
[sshd]
enabled = true
maxretry = 5
bantime = 1h
CONF
systemctl enable --now fail2ban

echo
echo "Fertig. Ab jetzt:  ssh $ADMIN_USER@<server>"
echo "Root-Login und Passwörter sind deaktiviert. Teste den neuen Login, bevor du diese Sitzung schließt!"
