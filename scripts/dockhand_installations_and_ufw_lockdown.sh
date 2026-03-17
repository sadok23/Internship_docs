#!/bin/bash
set -e

# ─────────────────────────────────────────────────────────────────────────────
# 1. Root check
# ─────────────────────────────────────────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
  echo "Error: Please run this script with sudo."
  echo "Usage: sudo $0"
  exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# 2. Detect SSH client IP automatically from the active session
# ─────────────────────────────────────────────────────────────────────────────
# $SSH_CONNECTION = "client_ip client_port server_ip server_port"
# $SSH_CLIENT     = "client_ip client_port server_port"
# Both are set by the SSH daemon — no argument needed.
if [[ -n "${SSH_CONNECTION:-}" ]]; then
  SSH_IP=$(echo "$SSH_CONNECTION" | awk '{print $1}')
elif [[ -n "${SSH_CLIENT:-}" ]]; then
  SSH_IP=$(echo "$SSH_CLIENT" | awk '{print $1}')
else
  echo "Error: Could not detect SSH client IP."
  echo "Neither \$SSH_CONNECTION nor \$SSH_CLIENT is set."
  echo "Are you running this inside an active SSH session?"
  exit 1
fi

echo "--- Detected SSH source IP: $SSH_IP ---"
echo "--- Ctrl-C within 10s to abort ---"
sleep 10

ACTUAL_USER=${SUDO_USER:-$USER}
echo "--- Starting Setup for User: $ACTUAL_USER | Admin IP: $SSH_IP ---"

# ─────────────────────────────────────────────────────────────────────────────
# 3. Install Prerequisites
# ─────────────────────────────────────────────────────────────────────────────
apt-get update -qq
apt-get install -y ufw curl wget iptables

# ─────────────────────────────────────────────────────────────────────────────
# 4. Install Docker
# ─────────────────────────────────────────────────────────────────────────────
echo "--- Installing Docker Engine ---"
curl -fsSL https://get.docker.com -o get-docker.sh
sh get-docker.sh
rm get-docker.sh

echo "--- Enabling Non-Sudo Docker for $ACTUAL_USER ---"
groupadd -f docker || true
usermod -aG docker "$ACTUAL_USER"

# ─────────────────────────────────────────────────────────────────────────────
# 5. Install ufw-docker BEFORE enabling UFW
# ─────────────────────────────────────────────────────────────────────────────
echo "--- Installing ufw-docker ---"
wget -qO /usr/local/bin/ufw-docker \
  https://github.com/chaifeng/ufw-docker/raw/master/ufw-docker
chmod +x /usr/local/bin/ufw-docker
/usr/local/bin/ufw-docker install

# ─────────────────────────────────────────────────────────────────────────────
# 6. Deploy Dockhand FIRST — we need its container IP for the UFW rule
# ─────────────────────────────────────────────────────────────────────────────
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

CONTAINER_IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' dockhand)

if [ -z "$CONTAINER_IP" ]; then
  echo "Error: Could not resolve Dockhand container IP. Container may have failed to start."
  docker logs dockhand
  exit 1
fi

echo "--- Dockhand container IP: $CONTAINER_IP ---"

# ─────────────────────────────────────────────────────────────────────────────
# 7. Configure UFW
# ─────────────────────────────────────────────────────────────────────────────
echo "--- Configuring UFW (Allowing $SSH_IP ONLY) ---"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw default deny routed

# SSH — INPUT chain, host-level
ufw allow from "$SSH_IP" to any port 22 proto tcp \
  comment 'SSH - admin IP only'

# Dockhand — FORWARD chain (DOCKER-USER), scoped to exact container IP + port
ufw route allow proto tcp \
  from "$SSH_IP" to "$CONTAINER_IP" port 3000 \
  comment 'Dockhand route - admin IP only'

ufw --force enable
ufw reload

# ─────────────────────────────────────────────────────────────────────────────
# Persist admin IP for future reference (e.g. the refresh script)
# ─────────────────────────────────────────────────────────────────────────────
cat > /etc/ufw-admin-ip.conf <<EOF
# Written by setup.sh on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
ADMIN_IP=$SSH_IP
EOF

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
SERVER_IP=$(hostname -I | awk '{print $1}')
echo "----------------------------------------------------------------"
echo "SUCCESS: Infrastructure is ready and strictly locked down."
echo ""
echo "  Admin IP       : $SSH_IP"
echo "  SSH            : port 22                    → admin IP only"
echo "  Dockhand       : http://$SERVER_IP:8080     → admin IP only"
echo "  Container IP   : $CONTAINER_IP:3000"
echo "  All other inbound + forwarded traffic: DENIED"
echo ""
echo "  To use Docker without sudo, run:"
echo "    newgrp docker"
echo "----------------------------------------------------------------"
echo ""
ufw status verbose
echo ""
ufw-docker status
