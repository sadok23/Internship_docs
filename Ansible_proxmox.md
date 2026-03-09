# Infrastructure Provisioning with Ansible & Proxmox

## Table of Contents
- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Setup](#1-setup)
- [Inventory](#2-inventory)
- [Playbooks](#3-playbooks)
- [Running a Playbook](#4-running-a-playbook)

---

## Overview

This guide covers how to provision Proxmox infrastructure using Ansible playbooks. Ansible communicates with Proxmox via the `proxmoxer` library, which wraps the Proxmox API — no need to SSH into the Proxmox host for most operations.

---

## Prerequisites

- Python 3 installed on the control machine
- Access to the Proxmox host (`20.0.0.202`) with a valid API token
- The playbooks cloned/available under the `ansible/` folder of this repo

---

## 1. Setup

### Create a virtual environment

It's recommended to use a virtual environment to avoid dependency conflicts with other Python projects on your machine.

```bash
python3 -m venv venv
source venv/bin/activate
```

### Install dependencies

```bash
pip install \
  ansible==13.3.0 \
  ansible-core==2.20.2 \
  proxmoxer==2.2.0 \
  requests==2.32.5 \
  cryptography==46.0.4 \
  PyYAML==6.0.3 \
  Jinja2==3.1.6 \
  jmespath==1.1.0
```

Or install everything at once using the `requirements.txt` file at the root of the repo:

```bash
pip install -r requirements.txt
```

> 💡 Always activate the venv before running any Ansible commands. If you see `ansible: command not found`, you likely forgot to run `source venv/bin/activate`.

### Full dependency list

| Package | Version |
|---------|---------|
| ansible | 13.3.0 |
| ansible-core | 2.20.2 |
| proxmoxer | 2.2.0 |
| requests | 2.32.5 |
| cryptography | 46.0.4 |
| PyYAML | 6.0.3 |
| Jinja2 | 3.1.6 |
| jmespath | 1.1.0 |
| certifi | 2026.1.4 |
| cffi | 2.0.0 |
| charset-normalizer | 3.4.4 |
| idna | 3.11 |
| MarkupSafe | 3.0.3 |
| packaging | 26.0 |
| pycparser | 3.0 |
| resolvelib | 1.2.1 |
| urllib3 | 2.6.3 |

---

## 2. Inventory

The inventory file tells Ansible where the Proxmox host is and how to authenticate against its API. It is located at `ansible/inventory.yml`.

```yaml
all:
  hosts:
    proxmox:
      ansible_host: 20.0.0.202
      ansible_user: root
      pve_api_user: root@pam
      proxmox_token_id: "root@pam!ansible"
      proxmox_token_secret: <your-token-secret>
```



### Inventory fields explained

| Field | Description |
|-------|-------------|
| `ansible_host` | IP of the Proxmox node |
| `ansible_user` | SSH user (used for connection fallback) |
| `pve_api_user` | Proxmox API user in `user@realm` format |
| `proxmox_token_id` | API token ID in `user@realm!tokenname` format |
| `proxmox_token_secret` | The secret generated when the token was created in Proxmox |

---

## 3. Playbooks

All playbooks are located in the `ansible/playbooks/` folder. Each playbook handles a specific provisioning task.

```
ansible/
├── inventory.yml
├── requirements.txt
└── playbooks/
    ├── create-vm.yml
    ├── clone-template.yml
    └── ...
```

> 💡 Open the individual playbook files for variable definitions and usage notes specific to each task.

---

## 4. Running a Playbook

Make sure the venv is active, then run:

```bash
ansible-playbook -i ansible/inventory.yml ansible/playbooks/<playbook-name>.yml
```

For example, to run `create-vm.yml`:

```bash
ansible-playbook -i ansible/inventory.yml ansible/playbooks/create-vm.yml
```

If your inventory contains vault-encrypted secrets, add `--ask-vault-pass`:

```bash
ansible-playbook -i ansible/inventory.yml ansible/playbooks/create-vm.yml --ask-vault-pass
```

To do a dry run without making any changes:

```bash
ansible-playbook -i ansible/inventory.yml ansible/playbooks/create-vm.yml --check
```

> 💡 Use `-v`, `-vv`, or `-vvv` to increase verbosity when debugging a failing playbook.
