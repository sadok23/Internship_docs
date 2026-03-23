#!/bin/bash
set -e

SSH_IP="20.0.0.84"
ACTUAL_USER="astro"

echo "--- Admin IP  : $SSH_IP ---"
echo "--- Setup for : $ACTUAL_USER ---"

# ── 1. Prerequisites ───────────────────────────────────────────────
apt-get update -qq
apt-get install -y ufw curl wget iptables

# ── 2. Docker log rotation ─────────────────────────────────────────
echo "--- Configuring Docker log rotation ---"
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<EOF
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF

# ── 3. Docker ──────────────────────────────────────────────────────
echo "--- Installing Docker Engine ---"
curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
sh /tmp/get-docker.sh
rm /tmp/get-docker.sh

echo "--- Adding $ACTUAL_USER to docker group ---"
groupadd -f docker || true
usermod -aG docker "$ACTUAL_USER"

# ── 4. Enable UFW before ufw-docker ───────────────────────────────
echo "--- Enabling UFW ---"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw default deny routed

# SSH open temporarily so Ansible can finish
ufw allow from "$SSH_IP" to any port 22 proto tcp comment 'SSH - admin IP only'
ufw --force enable

# ── 5. ufw-docker ──────────────────────────────────────────────────
echo "--- Installing ufw-docker ---"
wget -qO /usr/local/bin/ufw-docker \
  https://raw.githubusercontent.com/chaifeng/ufw-docker/master/ufw-docker
chmod +x /usr/local/bin/ufw-docker
/usr/local/bin/ufw-docker install
systemctl restart docker

# ── 6. Deploy Traefik ──────────────────────────────────────────────
echo "--- Deploying Traefik ---"
mkdir -p /opt/traefik

cat > /opt/traefik/traefik.yml <<EOF
api:
  dashboard: true
  insecure: true
providers:
  docker:
    exposedByDefault: false
entryPoints:
  web:
    address: ":80"
  websecure:
    address: ":443"
log:
  level: INFO
EOF

docker rm -f traefik 2>/dev/null || true
docker run -d \
  --name traefik \
  --restart unless-stopped \
  -p 80:80 \
  -p 443:443 \
  -p 8081:8080 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /opt/traefik/traefik.yml:/etc/traefik/traefik.yml \
  traefik:latest

# ── 7. Deploy Dockhand ─────────────────────────────────────────────
echo "--- Deploying Dockhand ---"
mkdir -p /opt/dockhand
docker rm -f dockhand 2>/dev/null || true

docker run -d \
  --name dockhand \
  --restart unless-stopped \
  -p 8080:3000 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /opt/dockhand:/app/data \
  -e HOST_DATA_DIR=/opt/dockhand \
  fnsys/dockhand:latest

# ── 8. Get container IPs ───────────────────────────────────────────

TRAEFIK_IP=$(docker inspect \
  -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' traefik)
DOCKHAND_IP=$(docker inspect \
  -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' dockhand)

if [ -z "$TRAEFIK_IP" ] || [ -z "$DOCKHAND_IP" ]; then
  echo "Error: Could not resolve container IPs."
  docker logs traefik
  docker logs dockhand
  exit 1
fi

echo "--- Traefik IP   : $TRAEFIK_IP ---"
echo "--- Dockhand IP  : $DOCKHAND_IP ---"

# ── 9. UFW rules for existing containers only ──────────────────────
echo "--- Configuring UFW container rules ---"

# Traefik — ports 80, 443, 8080 (dashboard) from admin IP only
ufw route allow proto tcp from "$SSH_IP" to "$TRAEFIK_IP" port 80 \
  comment 'Traefik HTTP - admin IP only'
ufw route allow proto tcp from "$SSH_IP" to "$TRAEFIK_IP" port 443 \
  comment 'Traefik HTTPS - admin IP only'
ufw route allow proto tcp from "$SSH_IP" to "$TRAEFIK_IP" port 8080 \
  comment 'Traefik dashboard - admin IP only'

# Dockhand — port 3000 (internal) from admin IP only
ufw route allow proto tcp from "$SSH_IP" to "$DOCKHAND_IP" port 3000 \
  comment 'Dockhand - admin IP only'

ufw reload

# ── Persist admin IP ───────────────────────────────────────────────
cat > /etc/ufw-admin-ip.conf <<EOF
# Written by Ansible provision on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
ADMIN_IP=$SSH_IP
EOF

# ── Summary ────────────────────────────────────────────────────────
SERVER_IP=$(hostname -I | awk '{print $1}')
echo "----------------------------------------------------------------"
echo "SUCCESS"
echo "  Admin IP      : $SSH_IP"
echo "  SSH           : port 22 (temporarily open — locked after)"
echo "  Traefik HTTP  : http://$SERVER_IP:80       → admin IP only"
echo "  Traefik HTTPS : https://$SERVER_IP:443     → admin IP only"
echo "  Traefik UI    : http://$SERVER_IP:8081     → admin IP only"
echo "  Dockhand      : http://$SERVER_IP:8080     → admin IP only"
echo "----------------------------------------------------------------"
ufw status verbose
ufw-docker status
