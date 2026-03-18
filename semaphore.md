# Semaphore — Installation & Usage Guide

> Ansible automation UI running on Docker with PostgreSQL, connected to Proxmox for VM provisioning.

---

## Table of Contents

- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [First Login](#first-login)
- [Proxmox API Token](#proxmox-api-token)
- [Install community.general in Semaphore](#install-communitygeneral-in-semaphore)
- [Project Setup](#project-setup)
  - [1. Repository](#1-repository)
  - [2. Inventory](#2-inventory)
  - [3. Variable Group](#3-variable-group)
  - [4. Task Template](#4-task-template)
- [Running the Playbook](#running-the-playbook)
- [Useful Commands](#useful-commands)

---

## Prerequisites

- Docker and Docker Compose installed
- A Proxmox host accessible on your network
- Your playbooks stored in a GitHub repository

---

## Installation

### 1. Create the project directory

```bash
mkdir -p ~/semaphore
cd ~/semaphore
```

### 2. Create `docker-compose.yml`

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
      - semaphore-config:/etc/semaphore

volumes:
  semaphore-postgres-data:
  semaphore-config:
```

### 3. Start Semaphore

```bash
docker compose up -d
```

Semaphore will be available at:

```
http://<your-server-ip>:3001
```

---

## First Login

| Field    | Value   |
|----------|---------|
| Username | `admin` |
| Password | `admin` |

> ⚠️ Change the admin password after first login via **Team → Edit User**.

---

## Proxmox API Token

Semaphore communicates with Proxmox through an API token. Here is how to create one with the right permissions.

### 1. Create the token

In the Proxmox web UI go to **Datacenter → Permissions → API Tokens → Add**.

| Field | Value |
|-------|-------|
| User | `root@pam` |
| Token ID | `ansible` |
| Privilege Separation | **Unchecked** |

> Unchecking **Privilege Separation** means the token inherits root permissions. This is required for VM cloning, cloud-init configuration, and starting VMs.

Click **Add** and copy the token secret — it is only shown once.

Your token will look like this:

```
Token ID:     root@pam!ansible
Token Secret: d12ac917-dc0f-4ccb-ae8b-76f43476bbd4
```

### 2. Verify permissions

Since `root@pam` with privilege separation disabled inherits full permissions, no additional role assignment is needed. If you use a non-root user you would need to assign at minimum the `PVEAdmin` role at the Datacenter level.

---

## Install community.general in Semaphore

The provisioning playbook uses `community.general.proxmox_kvm` which is not included in the default Ansible installation inside the Semaphore container. You need to install it manually into the Ansible virtual environment.

### 1. Exec into the container

```bash
docker exec -it semaphore /bin/sh
```

### 2. Find the Ansible venv

```bash
find / -name "ansible" -type f 2>/dev/null | grep bin
```

It will typically be at `/usr/lib/python3/dist-packages/` or inside a venv like `/usr/local/lib/python3.x/`.

### 3. Install the collection

```bash
ansible-galaxy collection install community.general
```

### 4. Verify

```bash
ansible-galaxy collection list | grep community.general
```

### 5. Exit the container

```bash
exit
```

> This installation persists as long as the container is not recreated. If you run `docker compose down && docker compose up`, you will need to repeat this step — or mount a persistent volume for the Ansible collections directory.

---

## Project Setup

In Semaphore, create a new **Project** first. Everything below lives inside it.

**Navigate to:** `Projects → + New Project` → give it a name like `Proxmox Provisioning`.

---

### 1. Repository

The Repository connects Semaphore to your GitHub repo where the playbooks live.

**Navigate to:** Project → Repositories → `+ New Repository`

| Field | Value |
|-------|-------|
| Name | `provisioning-playbooks` |
| URL | `https://github.com/<your-username>/<your-repo>` |
| Branch | `main` |
| Access Key | None *(for public repos)* or a GitHub token key for private repos |

---

### 2. Inventory

The Inventory defines your Proxmox host and the API credentials Ansible uses to talk to it.

**Navigate to:** Project → Inventory → `+ New Inventory`

| Field | Value |
|-------|-------|
| Name | `proxmox` |
| Type | `YAML` |
| SSH Key | None |

**Inventory content:**

```yaml
all:
  hosts:
    proxmox:
      ansible_host: 20.0.0.202
      ansible_user: root
      pve_api_user: root@pam
      proxmox_token_id: "root@pam!ansible"
      proxmox_token_secret: d12ac917-dc0f-4ccb-ae8b-76f43476bbd4
```

Replace `ansible_host` with your Proxmox IP and the token values with your own.

---

### 3. Variable Group

The Variable Group holds the per-run variables passed to the playbook as extra vars. This is where you configure what VM gets created.

**Navigate to:** Project → Variable Groups → `+ New Variable Group`

| Field | Value |
|-------|-------|
| Name | `dockhand-vars` |

**Variables (JSON):**

```json
{
  "new_vm_name": "dockhand-node",
  "vm_user": "astro",
  "vm_password": "your-secure-password",
  "ssh_ip": "your-admin-ip"
}
```

| Variable | Description |
|----------|-------------|
| `new_vm_name` | Base name for the VM — VMID is appended automatically |
| `vm_user` | User created on the VM via cloud-init |
| `vm_password` | Password for that user |
| `ssh_ip` | The only IP that will be allowed to SSH into the VM after provisioning |

> `ssh_ip` is critical — once the playbook finishes, UFW locks SSH to this IP only.

---

### 4. Task Template

The Task Template ties everything together.

**Navigate to:** Project → Task Templates → `+ New Template`

| Field | Value |
|-------|-------|
| Name | `Provision Dockhand VM` |
| Playbook Filename | `provision_dockhand.yml` |
| Inventory | `proxmox` |
| Repository | `provisioning-playbooks` |
| Variable Group | `dockhand-vars` |

---

## Running the Playbook

1. Navigate to **Task Templates**
2. Click **Run** on `Provision Dockhand VM`
3. Optionally override variable group values for this specific run (e.g. different `new_vm_name` or `ssh_ip`)
4. Click **Confirm**

Semaphore streams the full Ansible output in real time under the **Tasks** tab.

### What the playbook does

| Steps | Action |
|-------|--------|
| 1–2 | Gets next available VMID from Proxmox API |
| 3 | Clones the template into a new VM named `<new_vm_name>-<vmid>` |
| 4 | Applies cloud-init credentials and DHCP |
| 5–5b | Starts the VM, waits for cloud-init to complete |
| 6–7 | Configures user, enables SSH password auth, reboots |
| 8–9 | Discovers the VM IP via QEMU guest agent |
| 10–15 | SSHes in, installs Docker, Traefik, Dockhand, configures UFW |
| 18 | Locks SSH to `ssh_ip` only |

> To increase verbosity add `-vvv` to **Extra CLI Arguments** in the Task Template settings.

---

## Useful Commands

```bash
# Start Semaphore
docker compose up -d

# Stop Semaphore
docker compose down

# View logs
docker logs semaphore

# Restart Semaphore only
docker compose restart semaphore

# Update to latest image
docker compose pull && docker compose up -d

# Exec into container (e.g. to install collections)
docker exec -it semaphore /bin/sh
```
