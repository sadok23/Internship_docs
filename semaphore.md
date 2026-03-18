# Semaphore — Installation & Usage Guide

> Ansible automation UI powered by Semaphore, running on Docker with PostgreSQL.

---

## Table of Contents

- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [First Login](#first-login)
- [Project Setup](#project-setup)
  - [1. Key Store](#1-key-store)
  - [2. Repository](#2-repository)
  - [3. Inventory](#3-inventory)
  - [4. Environment](#4-environment)
  - [5. Task Template](#5-task-template)
- [Running the Dockhand Provisioning Playbook](#running-the-dockhand-provisioning-playbook)
- [Folder Structure](#folder-structure)
- [Useful Commands](#useful-commands)

---

## Prerequisites

- Docker and Docker Compose installed
- A machine accessible on your network
- Your Ansible playbooks stored locally or in a Git repository

---

## Installation

### 1. Create the project directory

```bash
mkdir -p ~/semaphore/playbooks
cd ~/semaphore
```

### 2. Create the `docker-compose.yml`

```yaml
services:
  semaphore-db:
    image: postgres:14-alpine
    container_name: semaphore-db
    restart: unless-stopped
    volumes:
      - semaphore-postgres-data:/var/lib/postgresql/data
    environment:
      - POSTGRES_USER=semaphore
      - POSTGRES_PASSWORD=semaphore_pass
      - POSTGRES_DB=semaphore

  semaphore:
    image: semaphoreui/semaphore:latest
    container_name: semaphore
    ports:
      - "3001:3000"
    restart: unless-stopped
    environment:
      - SEMAPHORE_DB_USER=semaphore
      - SEMAPHORE_DB_PASS=semaphore_pass
      - SEMAPHORE_DB_HOST=semaphore-db
      - SEMAPHORE_DB_PORT=5432
      - SEMAPHORE_DB_DIALECT=postgres
      - SEMAPHORE_DB=semaphore
      - SEMAPHORE_ADMIN_PASSWORD=admin
      - SEMAPHORE_ADMIN_NAME=Admin
      - SEMAPHORE_ADMIN_EMAIL=admin@example.com
      - SEMAPHORE_ADMIN=admin
      - ANSIBLE_HOST_KEY_CHECKING=False
    depends_on:
      - semaphore-db
    volumes:
      - ./playbooks:/tmp/semaphore/playbooks
      - semaphore-config:/etc/semaphore

volumes:
  semaphore-postgres-data:
  semaphore-config:
```

### 3. Start Semaphore

```bash
docker compose up -d
```

### 4. Verify containers are running

```bash
docker ps
```

Both `semaphore` and `semaphore-db` should show as `Up`.

Semaphore is now accessible at:

```
http://<your-server-ip>:3001
```

---

## First Login

| Field    | Value              |
|----------|--------------------|
| Username | `admin`            |
| Password | `admin`            |

> ⚠️ Change the admin password immediately after first login via **Team → Edit User**.

---

## Project Setup

Everything in Semaphore lives inside a **Project**. Before you can run a playbook you need to configure five things in order.

### 1. Key Store

The Key Store holds credentials used by Ansible — SSH keys, passwords, and API tokens.

**Navigate to:** Project → Key Store → `+ New Key`

#### SSH Key (for connecting to VMs)

| Field | Value |
|-------|-------|
| Name | `vm-ssh-key` |
| Type | `SSH Key` |
| Private Key | Paste your private key |

#### Proxmox API Token (for the provisioning playbook)

| Field | Value |
|-------|-------|
| Name | `proxmox-token` |
| Type | `Login with password` |
| Login | `user@pve!tokenid` |
| Password | `your-token-secret` |

> The playbook reads `proxmox_token_id` and `proxmox_token_secret` from the inventory. See [Inventory](#3-inventory) below.

---

### 2. Repository

The Repository tells Semaphore where your playbooks live. Since playbooks are mounted directly into the container at `/tmp/semaphore/playbooks`, you can use a **local path** without needing Git.

**Navigate to:** Project → Repositories → `+ New Repository`

| Field | Value |
|-------|-------|
| Name | `local-playbooks` |
| URL | `/tmp/semaphore/playbooks` |
| Branch | `main` *(ignored for local paths)* |
| Access Key | `None` |

> If you prefer Git, set the URL to your repo URL and select the appropriate SSH or token key.

---

### 3. Inventory

The Inventory defines the target hosts and variables Ansible will use.

**Navigate to:** Project → Inventory → `+ New Inventory`

| Field | Value |
|-------|-------|
| Name | `proxmox-hosts` |
| Type | `Static` |
| SSH Key | `vm-ssh-key` |

**Inventory content:**

```ini
[proxmox]
<your-proxmox-ip> ansible_user=root

[proxmox:vars]
proxmox_token_id=user@pve!tokenid
proxmox_token_secret=your-token-secret
```

Replace `<your-proxmox-ip>`, `proxmox_token_id`, and `proxmox_token_secret` with your actual values.

---

### 4. Environment

The Environment holds extra variables passed to the playbook at runtime. This is where you set the per-run values like the VM name and admin IP.

**Navigate to:** Project → Environment → `+ New Environment`

| Field | Value |
|-------|-------|
| Name | `dockhand-vars` |

**Extra variables (JSON):**

```json
{
  "new_vm_name": "dockhand-node",
  "vm_user": "astro",
  "vm_password": "your-secure-password",
  "ssh_ip": "your-admin-ip"
}
```

> `ssh_ip` must be the IP of the machine you will SSH from after provisioning. This is the only IP that will be allowed through UFW after the playbook completes.

---

### 5. Task Template

The Task Template ties everything together — it defines which playbook to run and with which inventory, environment, and repository.

**Navigate to:** Project → Task Templates → `+ New Template`

| Field | Value |
|-------|-------|
| Name | `Provision Dockhand VM` |
| Playbook Filename | `provision_dockhand.yml` |
| Inventory | `proxmox-hosts` |
| Repository | `local-playbooks` |
| Environment | `dockhand-vars` |
| Vault Password | *(leave empty unless using Ansible Vault)* |

---

## Running the Dockhand Provisioning Playbook

### Place the playbook

Copy `provision_dockhand.yml` into the `playbooks` folder on your server:

```bash
cp provision_dockhand.yml ~/semaphore/playbooks/
```

The file is immediately available inside the container at `/tmp/semaphore/playbooks/provision_dockhand.yml`.

### Run the task

1. Navigate to **Task Templates**
2. Click **Run** on `Provision Dockhand VM`
3. Optionally override any extra variables for this specific run (e.g. change `new_vm_name`)
4. Click **Confirm**

### What happens

| Step | What Semaphore / Ansible does |
|------|-------------------------------|
| 1–2 | Gets next available VMID from Proxmox API |
| 3 | Clones template `102` into a new VM named `<new_vm_name>-<vmid>` |
| 4 | Sets cloud-init credentials and DHCP |
| 5 | Starts the VM, waits for cloud-init to finish |
| 6 | Creates user, enables SSH password auth, reboots |
| 7–9 | Discovers VM IP via QEMU guest agent |
| 10–15 | SSHes into the VM, installs Docker, Traefik, Dockhand, configures UFW |
| 18 | Locks SSH access to `ssh_ip` only |

### Monitor the run

Semaphore streams the full Ansible output in real time under the **Tasks** tab. Each task is numbered and matches the playbook task names.

> To increase verbosity, add `-vvv` to **Extra CLI Arguments** in the Task Template settings.

---

## Folder Structure

```
~/semaphore/
├── docker-compose.yml
└── playbooks/
    └── provision_dockhand.yml
```

---

## Useful Commands

```bash
# Start Semaphore
docker compose up -d

# Stop Semaphore
docker compose down

# View logs
docker logs semaphore

# Restart only Semaphore (keep DB running)
docker compose restart semaphore

# Update to latest image
docker compose pull && docker compose up -d
```

---

> For issues with playbook execution, check the task log in Semaphore first. Common causes are incorrect Proxmox token permissions, wrong `ssh_ip`, or the template VMID not matching `template_id` in the playbook vars.
