# Borg Backup Platform Setup & Administration

## Table of Contents
- [Overview](#overview)
- [Architecture](#architecture)
- [Quick Start](#quick-start)
- [Docker Compose Deployment](#1-docker-compose-deployment)
- [Configuration](#2-configuration)
- [Web UI & Admin](#3-web-ui--admin)
- [Backup Clients Setup](#4-backup-clients-setup)
- [Repository Management](#5-repository-management)
- [Monitoring & Maintenance](#6-monitoring--maintenance)

---

## Overview

**Borg Backup Server (BBS)** is a modern backup solution that provides centralized backup management with web UI, SSH connectivity, and efficient deduplication.

| Component | Port | Role |
|-----------|------|------|
| **Web UI** | `8080` | Administrative interface for managing backups, repositories, and users |
| **SSH Server** | `2222` | Borg agent connection point for remote backup clients |
| **Database** | Internal | Stores metadata, user accounts, and backup catalog |
| **Repository Storage** | `/var/bbs` | Persistent volume for all backup data |

### Key Features
- **Deduplication**: Reduces storage by detecting identical data chunks
- **Encryption**: All backups are encrypted in transit and at rest
- **Web Dashboard**: Centralized management without CLI
- **Multi-tenant**: Support for multiple users and repositories
- **Docker-native**: Easy deployment and scaling

---

## Architecture

```
Backup Client #1         Backup Client #2         Backup Client #3
  (Linux VM)              (Linux VM)               (Docker Server)
   ┌──────────┐           ┌──────────┐            ┌──────────┐
   │ Borg CLI │           │ Borg CLI │            │ Borg CLI │
   │ Agent    │           │ Agent    │            │ Agent    │
   └──────┬───┘           └──────┬───┘            └──────┬───┘
          │                      │                       │
          └──────────────────────┼───────────────────────┘
                                 │
                      [SSH over Port 2222]
                                 │
                    ╔════════════▼═════════════╗
                    ║   Borg Backup Server     ║
                    ║ (Docker Container)       ║
                    ║ ┌─────────────────────┐  ║
                    ║ │ Web UI (Port 8080)  │  ║
                    ║ └─────────────────────┘  ║
                    ║ ┌─────────────────────┐  ║
                    ║ │ SSH (Port 2222)     │  ║
                    ║ └─────────────────────┘  ║
                    ║ ┌─────────────────────┐  ║
                    ║ │ Repository Storage  │  ║
                    ║ │ + MySQL Database    │  ║
                    ║ └─────────────────────┘  ║
                    ╚══════════════════════════╝
                            │
                    ┌───────▼────────┐
                    │  bbs-data      │
                    │  Docker Volume │
                    │  or Bind Mount │
                    └────────────────┘
```

---

## Quick Start

```bash
# Start the container
docker compose up -d

# View admin credentials (generated on first run)
docker compose logs bbs | grep -i "admin\|password"

# Access the web UI
# Navigate to http://localhost:8080 in your browser
```

---

## 1. Docker Compose Deployment

### Prerequisites
- Docker and Docker Compose installed
- At least 1GB storage available for backups
- Network access to SSH port 2222 from backup clients

### Docker Compose File

Save this as `docker-compose.yml`:

```yaml
# Borg Backup Server — Docker Compose
#
# Quick start:
#   docker compose up -d
#   docker compose logs bbs          # view admin credentials
#
# All data (database, repositories, SSH keys) is stored in the bbs-data volume.

services:
  bbs:
    image: marcpope/borgbackupserver:latest
    # build: .    # uncomment to build locally instead of pulling from Docker Hub
    container_name: bbs
    ports:
      - "8080:80" # Web UI
      - "2222:22" # SSH for borg agent connections
    environment:
      # Public URL — used by browsers and agents to reach BBS
      - APP_URL=http://localhost:8080
      # SSH port — MUST match the host-side port mapping above (left side of 2222:22)
      - SSH_PORT=2222
      # Admin password — only used on first run. Omit to auto-generate (shown in logs).
      # - ADMIN_PASS=changeme
    volumes:
      - bbs-data:/var/bbs
      # To store backups, MySQL, and ClickHouse catalog on a specific disk or path instead of Docker's internal storage,
      # replace the line above with a bind mount:
      # - /mnt/backups:/var/bbs
    restart: unless-stopped

volumes:
  bbs-data: # Remove this 'volumes' section entirely if using a bind mount above
```

### Deployment Steps

1. **Create project directory:**
```bash
mkdir -p /opt/borg-backup
cd /opt/borg-backup
```

2. **Create docker-compose.yml** with the configuration above

3. **Start the service:**
```bash
docker compose up -d
```

4. **Verify it's running:**
```bash
docker compose ps
```

### Using Bind Mount for Large Storage

If storing backups on a dedicated disk, modify the `docker-compose.yml`:

```yaml
volumes:
  bbs:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: /mnt/backups  # Change to your mount point
```

Then update the service volume:
```yaml
volumes:
  - bbs:/var/bbs
```

### Using TrueNAS NFS for Centralized Storage

For production environments with dedicated storage appliances, using **TrueNAS** with NFS provides centralized, redundant backup storage.

#### Step 1: Create NFS Share on TrueNAS

1. **Login to TrueNAS Web UI** at `https://20.0.0.109`
2. Navigate to **Storage** → **Pools** → Select your pool
3. Verify dataset exists (e.g., `disk-1`) for Borg data
4. Right-click → **Share** → **Unix (NFS)**
5. Configure NFS share settings:
   - **Mapall User**: `root` (or specific user)
   - **Mapall Group**: `wheel` (or specific group)
   - **Security**: Enable Kerberos or restrict to trusted IPs
6. Note the NFS path: `20.0.0.109:/mnt/disk-1`

#### Step 2: Mount NFS on Backup Server Host

**Install NFS client tools:**
```bash
# Debian/Ubuntu
sudo apt-get install nfs-common

# RHEL/CentOS
sudo dnf install nfs-utils

# Arch
sudo pacman -S nfs-utils
```

**Create mount directory:**
```bash
sudo mkdir -p /mnt/borg-backups
```

**Mount NFS share (temporary):**
```bash
sudo mount -t nfs -o rw,hard,intr 20.0.0.109:/mnt/disk-1 /mnt/borg-backups
```

**Verify mount:**
```bash
mount | grep borg-backups
df -h /mnt/borg-backups
```

**Persistent mount via fstab:**
Edit `/etc/fstab` and add:
```
20.0.0.109:/mnt/disk-1 /mnt/borg-backups nfs rw,hard,intr,_netdev 0 0
```

Then remount:
```bash
sudo mount -a
```

#### Step 3: Configure Docker Compose to Use NFS Mount

Update your `docker-compose.yml`:

```yaml
services:
  bbs:
    image: marcpope/borgbackupserver:latest
    container_name: bbs
    ports:
      - "8080:80"
      - "2222:22"
    environment:
      - APP_URL=http://localhost:8080
      - SSH_PORT=2222
    volumes:
      - /mnt/borg-backups:/var/bbs  # Bind mount the NFS path
    restart: unless-stopped
```

**Key advantages of NFS storage:**
- Centralized backup repository accessible from multiple servers
- TrueNAS handles RAID/redundancy automatically
- ZFS snapshots for disaster recovery
- Easy capacity expansion
- Network-based so independent from host hardware

#### Example: Multi-Server Backup Architecture

```
┌─────────────────────────────────────────────────────────┐
│              TrueNAS Storage (20.0.0.109)               │
│  ┌──────────────────────────────────────────────────┐   │
│  │  NFS Share: /mnt/disk-1                          │   │
│  │  ├─ ZFS Dataset (disk-1)                         │   │
│  │  │  └─ NFS Export: /mnt/disk-1                  │   │
│  │  │     ├─ RAID-Z2 (3+ drives)                   │   │
│  │  │     └─ Daily snapshots enabled                │   │
│  └──────────────────────────────────────────────────┘   │
└────────┬──────────────────────────────────────────────────┘
         │
         │ NFS (Port 2049)
         │ 20.0.0.109:/mnt/disk-1
         │
    ┌────┴────────────────────────────┐
    │                                 │
┌───▼────────────────────┐   ┌────────▼──────────────┐
│ BBS Server             │   │ Other Servers        │
│ (Backup Host)          │   │ (can also access     │
│ ┌────────────────────┐ │   │  backups via NFS)    │
│ │ /mnt/borg-backups  │ │   └──────────────────────┘
│ │ (NFS mount)        │ │
│ │                    │ │
│ │ Docker Container   │ │
│ │ Borg Backup Server │ │
│ │ :8080 (Web UI)     │ │
│ │ :2222 (SSH)        │ │
│ └────────────────────┘ │
└────────────────────────┘
```

---

## 2. Configuration

### Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `APP_URL` | `http://localhost:8080` | Public URL for web UI and client registration |
| `SSH_PORT` | `2222` | SSH port exposed to backup clients |
| `ADMIN_PASS` | auto-generated | Initial admin password (shown in logs if not set) |

### Important Configuration Points

**APP_URL:** Must be accessible from both your browser and backup clients
```yaml
environment:
  - APP_URL=http://192.168.1.100:8080  # Use your server's IP for remote access
```

**SSH_PORT:** Must match the left side of the port mapping
```yaml
ports:
  - "2222:22"  # Container's :22 exposed as :2222
environment:
  - SSH_PORT=2222
```

**Storage:** Use bind mount for production deployments
```yaml
volumes:
  - /mnt/backups:/var/bbs  # Persistent external storage
```

---

## 3. Web UI & Admin

### Accessing the Web Interface

1. Navigate to `http://localhost:8080` (or your configured APP_URL)
2. Login with **admin** / **password** from logs
3. Change the default password immediately

### Admin Tasks

#### Creating Users
1. Go to **Administration** → **Users**
2. Click **Create New User**
3. Set username and password
4. Configure permissions (optional)

#### Creating Repositories
1. Go to **Repositories** → **New Repository**
2. Set repository name (e.g., `client1-backup`)
3. Configure retention policies
4. Generate SSH keys for client access

#### Viewing Backups & Archives
1. Go to **Repositories** → Select repository
2. View archive list (each backup is an archive)
3. Check file list, timestamps, and sizes per backup
4. Browse and restore individual files if needed

---

## 4. Backup Clients Setup

### Prerequisites on Client
- **Borg Backup CLI** installed
  ```bash
  sudo apt-get install borgbackup  # Debian/Ubuntu
  sudo dnf install borgbackup      # RHEL/CentOS
  sudo pacman -S borg              # Arch
  ```
- SSH key-based authentication configured
- Network connectivity to BBS server

### Client Registration Workflow

1. **Create a repository in BBS Web UI** and note the SSH connection string
   - Format: `ssh://borg@server:2222/path/to/repo`

2. **On the client, initialize the backup:**
```bash
# First connection creates SSH key exchange
borg init --encryption=repokey ssh://borg@192.168.1.100:2222/backup/client1

# Enter passphrase when prompted
# Accept the remote host key
```

3. **Create your first backup:**
```bash
borg create \
  ssh://borg@192.168.1.100:2222/backup/client1::'hostname-{now:%Y-%m-%d_%H:%M:%S}' \
  /etc /home /var/www \
  --stats --progress
```

### Automated Backups with Cron

Create `/etc/cron.d/borg-backup`:

```bash
# Borg Backup - Daily at 2 AM
0 2 * * * root /usr/local/bin/borg-backup.sh >> /var/log/borg-backup.log 2>&1
```

Create `/usr/local/bin/borg-backup.sh`:

```bash
#!/bin/bash

REPO="ssh://borg@192.168.1.100:2222/backup/client1"
BACKUP_DIRS="/etc /home /var/www"
PASSPHRASE="YourPassphrase"

export BORG_PASSPHRASE=$PASSPHRASE

# Create backup
borg create \
  ${REPO}::'hostname-{now:%Y-%m-%d}' \
  ${BACKUP_DIRS} \
  --stats

# Prune old backups (keep last 7 daily, 4 weekly, 12 monthly)
borg prune \
  --keep-daily=7 \
  --keep-weekly=4 \
  --keep-monthly=12 \
  ${REPO}

exit 0
```

Make it executable:
```bash
chmod +x /usr/local/bin/borg-backup.sh
```

### Listing & Restoring Backups

```bash
# List all backups
borg list ssh://borg@192.168.1.100:2222/backup/client1

# List files in specific backup
borg list ssh://borg@192.168.1.100:2222/backup/client1::hostname-2026-03-09

# Extract entire backup to /tmp/restore
borg extract ssh://borg@192.168.1.100:2222/backup/client1::hostname-2026-03-09 --path=/tmp/restore

# Extract specific file
borg extract ssh://borg@192.168.1.100:2222/backup/client1::hostname-2026-03-09 etc/passwd
```

---

## 5. Repository Management

### Repository Info

```bash
# Get repository statistics
borg info ssh://borg@192.168.1.100:2222/backup/client1

# Output includes:
# - Total data size
# - Compressed size (after deduplication)
# - Number of archives
# - Encryption method
```

### Pruning Old Backups

Keep only recent backups to save space:

```bash
# Keep: 7 days, 4 weeks, 12 months
borg prune \
  --keep-daily=7 \
  --keep-weekly=4 \
  --keep-monthly=12 \
  ssh://borg@192.168.1.100:2222/backup/client1 \
  --stats
```

### Encryption & Security

**Default:** `repokey-blake2` encryption
- Encryption key stored in repository
- You must remember the passphrase

**Change passphrase:**
```bash
borg key change-passphrase ssh://borg@192.168.1.100:2222/backup/client1
```

**Export key for backup:**
```bash
borg key export ssh://borg@192.168.1.100:2222/backup/client1 /tmp/borg-key.txt
```

---

## 6. Monitoring & Maintenance

### Container Logs

```bash
# View all logs
docker compose logs bbs

# Follow logs in real-time
docker compose logs -f bbs

# View last 100 lines
docker compose logs --tail=100 bbs
```

### Database Backup

The MySQL database (containing backup metadata) is stored in the `bbs-data` volume:

```bash
# Backup the entire bbs-data volume
docker run --rm \
  -v bbs-data:/bbs-data \
  -v $(pwd):/backup \
  ubuntu tar czf /backup/bbs-data-backup.tar.gz -C /bbs-data .

# Restore from backup
docker run --rm \
  -v bbs-data:/bbs-data \
  -v $(pwd):/backup \
  ubuntu tar xzf /backup/bbs-data-backup.tar.gz -C /bbs-data
```

### Updating BBS

```bash
# Pull latest image
docker compose pull

# Restart with new image
docker compose up -d

# Verify update
docker compose logs bbs | head -20
```

### Monitoring Backup Success

Check the web UI or use the API:

```bash
# Query repository status via SSH
borg list ssh://borg@192.168.1.100:2222/backup/client1 --short
```

Set up Prometheus scrapes or log aggregation for production monitoring.

---

## Troubleshooting

### Connection Issues
```bash
# Test SSH connectivity
ssh -p 2222 borg@192.168.1.100

# Check SSH key fingerprint in logs
docker compose logs bbs | grep -i "key\|rsa"
```

### Passphrase/Access Issues
- If passphrase is forgotten, backups cannot be accessed
- Keep encrypted backup of passphrases in secure location
- Consider using key-file mode for automated backups

### Storage Issues
```bash
# Check volume usage
docker exec bbs du -sh /var/bbs

# Prune old backups to free space
borg prune --keep-daily=3 ssh://borg@192.168.1.100:2222/backup/client1
```

### Backup Failures
1. Check client connectivity: `ssh -p 2222 borg@server`
2. Verify repository path exists in BBS Web UI
3. Check client firewall (allow port 2222)
4. Review BBS container logs for SSH errors

---

## References
- [Borg Backup Documentation](https://borgbackup.readthedocs.io/)
- [Borg Backup Server GitHub](https://github.com/marcpope/borgbackupserver)
- [Docker Compose Documentation](https://docs.docker.com/compose/)
