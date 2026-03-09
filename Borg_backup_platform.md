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
                  ┌─────────▼──────────┐
                  │ TrueNAS (20.0.0.109)
                  │ /mnt/disk-1 (NFS)  │
                  └────────────────────┘
```

---



## 1. Docker Compose Deployment


### Docker Compose File


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
sudo apt-get install nfs-common

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
  - APP_URL=http:/<host-ip>:8080  # Use your server's IP for remote access
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

### Quick Access
- URL: `http://<host-ip>:8080` (or your configured APP_URL)
- Default login: **admin** / **password** (the generated password could be found in the container logs)

### Creating a Backup Plan

#### Step 0: Add Storage Location

1. **Left menu** → **Storage**
2. Click **Add Location**
3. Select the NFS volume mounted from TrueNAS (`/mnt/borg-backups`)
4. Click **Save**

#### Step 1: Add a Client

1. **Left dashboard** → **Clients**
2. Click **Add Client**
3. Enter client name (e.g., `server1`, `webhost-prod`)
4. Click **Create Client**
5. Copy the provided installation command and run it on the remote host:
   ```bash
   curl -s http://20.0.0.98:8080/get-agent | sudo bash -s -- --server http://20.0.0.98:8080 --key xxxxx-xxxxxx-xxxxxxx-xxxxxxxx
   ```
6. The agent will register itself and connect back to the server

#### Step 2: Configure Repository & Backup Plan

After the client connects, select it from the **Clients** list:

**Add Repository:**
- Click **Repositories** window
- Click **Add Repository**
- A **repository** is a backup destination specific to this client (like a backup vault)
- Repository naming: `{client-name}-backup` (e.g., `server1-backup`)

**Add Backup Plan:**
- Click **Plans** window  
- Click **Add Backup Plan**
- Configure the following:

| Setting | Options | Recommendation |
|---------|---------|-----------------|
| **Schedule** | Daily, Weekly, Monthly, Custom | Daily at 2:00 AM |
| **Folders to Backup** | Select multiple paths | `/etc`, `/home`, `/var/www`, etc. |
| **Compression** | None, LZ4, ZSTD, Auto | ZSTD (balanced speed/compression) |
| **Encryption** | Enabled by default | Keep enabled ✓ |
| **Retention** | Keep X daily/weekly/monthly | 7 daily, 4 weekly, 12 monthly |

4. Click **Save Plan** to activate automatic backups

#### Step 3: Restore Data

Select the client and go to **Restore** window:

**Option 1: Restore to Host**
- Select backup snapshot
- Choose destination path on the client
- Click **Restore** (files will be recovered on the client machine)

**Option 2: Download**
- Select backup snapshot
- Choose files/folders to download
- Click **Download** (files downloaded to your local machine)


```




