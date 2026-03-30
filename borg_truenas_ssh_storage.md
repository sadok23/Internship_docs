# Borg Backup + TrueNAS SCALE — SSH Remote Storage Setup

## Architecture

| Role | Details |
|---|---|
| **Borg Client** | Docker container |
| **Borg Remote** | TrueNAS SCALE at `20.0.0.109` |
| **Repo path** | `/mnt/disk-1/backups/nas` |
| **Encryption** | None |
| **Transport** | SSH (no NFS mount) |

---

## Part 1 — Install Borg on TrueNAS SCALE

TrueNAS SCALE has an immutable read-only rootfs — no `apt`, no `pkg`. The solution is a static binary placed on a ZFS dataset.

### 1. Download the static binary

```bash
wget https://github.com/borgbackup/borg/releases/download/1.2.8/borg-linux64 -O ~/borg
```

### 2. Move binary to dataset

`/home` is mounted `noexec` — the binary must live on the dataset.

```bash
sudo mkdir -p /mnt/disk-1/.tools
sudo mv ~/borg /mnt/disk-1/.tools/borg
sudo chmod +x /mnt/disk-1/.tools/borg
```

### 3. Create a custom TMPDIR

The PyInstaller binary extracts itself at runtime. All system `/tmp` paths are `noexec`, so we create a writable exec-safe temp dir on the dataset.

```bash
sudo mkdir -p /mnt/disk-1/.tools/tmp
sudo chmod 777 /mnt/disk-1/.tools/tmp
```

### 4. Persist PATH and TMPDIR

```bash
echo 'export PATH="/mnt/disk-1/.tools:$PATH"' >> ~/.zshrc
echo 'export TMPDIR=/mnt/disk-1/.tools/tmp' >> ~/.zshrc
source ~/.zshrc

borg --version
# Expected: borg 1.2.8
```

### 5. Create a wrapper script

Non-interactive SSH sessions (used by Borg over SSH) don't load `~/.zshrc`, so `TMPDIR` won't be set. A wrapper script fixes this.

```bash
sudo nano /mnt/disk-1/.tools/borg-wrapper.sh
```

```sh
#!/bin/sh
export TMPDIR=/mnt/disk-1/.tools/tmp
exec /mnt/disk-1/.tools/borg "$@"
```

```bash
sudo chmod +x /mnt/disk-1/.tools/borg-wrapper.sh
```

### Why each step was needed

| Problem | Root Cause | Fix |
|---|---|---|
| Can't install via `apt`/`pkg` | TrueNAS SCALE rootfs is immutable | Static binary from GitHub |
| `Permission denied` executing binary | `/home` mounted `noexec` | Moved to ZFS dataset |
| `libz.so.1` shared library error | PyInstaller extracts to `/tmp` which is `noexec` | Custom `TMPDIR` on dataset |
| `borg: command not found` | Binary not in `PATH` | Added `.tools` to `PATH` in `.zshrc` |
| `TMPDIR` not set in SSH sessions | Non-interactive SSH skips `.zshrc` | Wrapper script |

### Mount flags observed (for reference)

```
/home     → noexec (cannot run binaries)
/tmp      → noexec (cannot run binaries)
/mnt/disk-1 → no noexec (safe to use)
```

---

## Part 2 — SSH Key Setup

### 1. Generate key pair (on the client)

```bash
ssh-keygen -t ed25519 -C "borg-backup" -f ~/.ssh/borg_ed25519 -N ""
```

| Flag | Meaning |
|---|---|
| `-t ed25519` | Modern secure key type |
| `-f` | Dedicated key for Borg |
| `-N ""` | No passphrase (required for unattended backups) |

### 2. Copy public key to TrueNAS

```bash
echo "ssh-ed25519 <your_pub_key> borg-backup" >> ~/.ssh/authorized_keys
chmod 700 ~/.ssh
chmod 600 ~/.ssh/authorized_keys
```

### 3. Test SSH connection

```bash
ssh -i ~/.ssh/borg_ed25519 truenas_admin@20.0.0.109 \
  "TMPDIR=/mnt/disk-1/.tools/tmp /mnt/disk-1/.tools/borg --version"

# Expected: borg 1.2.8
```

---

## Part 3 — Initialize the Repository

Create the backups directory and give ownership to `truenas_admin`:

```bash
sudo mkdir -p /mnt/disk-1/backups
sudo chown truenas_admin:truenas_admin /mnt/disk-1/backups
```

Initialize the repo from the client:

```bash
BORG_REMOTE_PATH=/mnt/disk-1/.tools/borg-wrapper.sh \
borg init --encryption=none \
  ssh://truenas_admin@20.0.0.109//mnt/disk-1/backups/nas
```

---

## Part 4 — Data Recovery

### Option A — Recover directly on TrueNAS (fastest)

```bash
# List archives
borg list /mnt/disk-1/backups/nas

# Extract
sudo mkdir -p /mnt/disk-1/restore
cd /mnt/disk-1/restore

# NOTE: sudo does not inherit user PATH — use full binary path
sudo TMPDIR=/mnt/disk-1/.tools/tmp /mnt/disk-1/.tools/borg extract \
  /mnt/disk-1/backups/nas::<archive-name>

# Verify
ls /mnt/disk-1/restore
```

### Option B — Recover from a new machine

```bash
# 1. Install Borg
apt install borgbackup
# or static binary:
wget https://github.com/borgbackup/borg/releases/download/1.2.8/borg-linux64 -O /usr/local/bin/borg
chmod +x /usr/local/bin/borg

# 2. Restore SSH private key
cp borg_ed25519 ~/.ssh/borg_ed25519
chmod 600 ~/.ssh/borg_ed25519

# 3. List archives
BORG_REMOTE_PATH=/mnt/disk-1/.tools/borg-wrapper.sh \
borg list ssh://truenas_admin@20.0.0.109//mnt/disk-1/backups/nas

# 4. Extract
cd /restore/path
BORG_REMOTE_PATH=/mnt/disk-1/.tools/borg-wrapper.sh \
borg extract ssh://truenas_admin@20.0.0.109//mnt/disk-1/backups/nas::<archive-name>
```

### Minimum info needed to survive a full loss

| Item | Where to store |
|---|---|
| `borg_ed25519` private key | Bitwarden / Vaultwarden / USB |
| TrueNAS IP | `20.0.0.109` |
| Repo path | `/mnt/disk-1/backups/nas` |

---

## Part 5 — Timezone

Set the timezone on the client so archive timestamps are correct:

```bash
# In docker-compose.yml
environment:
  - TZ=Africa/Tunis
```

---

## Files Summary on TrueNAS

```
/mnt/disk-1/.tools/
├── borg                  # static binary (v1.2.8)
├── borg-wrapper.sh       # sets TMPDIR and execs borg
└── tmp/                  # PyInstaller extraction dir (chmod 777)

/mnt/disk-1/backups/
└── nas/                  # Borg repository (owned by truenas_admin)
```

---

## Troubleshooting

| Error | Cause | Fix |
|---|---|---|
| `zsh: command not found: pkg` | TrueNAS SCALE is not FreeBSD | Use static binary |
| `Permission denied` executing binary | `/home` is `noexec` | Move binary to dataset |
| `libz.so.1: failed to map segment` | `/tmp` is `noexec` | Set `TMPDIR` to dataset path |
| `borg: command not found` | Binary not in `PATH` | Add to `PATH` in `~/.zshrc` |
| `TMPDIR` not set in SSH session | Non-interactive SSH skips `.zshrc` | Use wrapper script |
| `PermissionError` on `borg init` | `truenas_admin` lacks write access | `mkdir` + `chown` the backups dir |
| `sudo: borg not found` | `sudo` doesn't inherit user `PATH` | Use full path: `sudo TMPDIR=... /mnt/disk-1/.tools/borg` |
