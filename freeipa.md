# FreeIPA + Self-Service Password + Proxmox LDAP Sync

---

## 1. FreeIPA Server

FreeIPA is a full identity management stack — it bundles a **389 Directory Server** (LDAP), **MIT Kerberos**, and a **PKI/CA** into a single container. That's why `--privileged` is mandatory: it needs real kernel-level access that normal containers don't get.

```bash
sudo docker run -it \
  --name freeipa-server \
  --hostname ipa.asteroidea.com \
  --privileged \
  -v /opt/freeipa-data:/data \
  -p 80:80 \
  -p 443:443 \
  -p 389:389 \
  -p 636:636 \
  -p 88:88 \
  -p 464:464 \
  -p 88:88/udp \
  -p 464:464/udp \
  freeipa/freeipa-server:almalinux-10 \
  ipa-server-install \
    --realm=ASTEROIDEA.COM \
    --domain=asteroidea.com \
    --hostname=ipa.asteroidea.com \
    --ds-password='<DS_PASSWORD>' \
    --admin-password='<ADMIN_PASSWORD>' \
    --unattended \
    --no-ntp
```

- `--hostname ipa.asteroidea.com` — FreeIPA hardcodes this into every certificate and Kerberos principal it generates at install time. It must match what clients use to reach it, otherwise TLS and Kerberos break.
- `-v /opt/freeipa-data:/data` — persists the entire identity server (LDAP database, CA, Kerberos keys) across container restarts. Without this, everything is wiped on restart.
- `--no-ntp` — skips the built-in Chrony setup since the host manages time sync. Keep the host clock accurate — Kerberos has a 5-minute skew tolerance and hard-rejects auth if clocks drift.
- Ports `88` and `464` (TCP + UDP) — Kerberos authentication and the `kpasswd` service. Both need TCP and UDP because Kerberos uses UDP for small packets and falls back to TCP for larger ones.

---

## 2. Self-Service Password Portal

SSP allows users to reset their FreeIPA password via a web interface without admin intervention. It talks to FreeIPA over LDAP and sends reset tokens by email through a Postfix relay.

### docker-compose.yml

```yaml
version: "3.8"
services:
  self-service-password:
    image: ltbproject/self-service-password
    container_name: self-service-password
    ports:
      - "8080:80"
    networks:
      - ipa-net
    volumes:
      - ./config.inc.local.php:/var/www/conf/config.inc.local.php:ro
    environment:
      - LDAP_URL=ldap://172.18.0.10
      - LDAP_BINDDN=uid=admin,cn=users,cn=accounts,dc=asteroidea,dc=com
      - LDAP_BINDPW=Asteroidea4711$%!
      - LDAP_BASE=cn=users,cn=accounts,dc=asteroidea,dc=com
      - SMTP_HOST=smtp-relay
      - SMTP_PORT=25
      - MAIL_FROM=sadokh923@gmail.com
      - USE_TOKEN=1
    depends_on:
      - smtp-relay
    restart: unless-stopped

  smtp-relay:
    image: juanluisbaptiste/postfix:latest
    container_name: smtp-relay
    networks:
      - ipa-net
    environment:
      - SMTP_SERVER=smtp.gmail.com
      - SMTP_PORT=587
      - SMTP_USERNAME=sadokh923@gmail.com
      - SMTP_PASSWORD=xxxxxxxxxxxxxx
      - SERVER_HOSTNAME=ipa.asteroidea.com
      - ACCEPTED_NETWORKS=172.18.0.0/16 127.0.0.0/8
      - SMTP_INTERFACE=0.0.0.0
    restart: unless-stopped

networks:
  ipa-net:
    external: true
```

- `ipa-net: external: true` — this network must already exist on the host (`docker network create ipa-net`). It's shared with the `freeipa-server` container (started separately via `docker run`), which is what allows SSP to reach FreeIPA by container name.
- The env vars on the SSP service (`LDAP_URL`, `LDAP_BINDDN`, etc.) are **overridden by the mounted PHP config file**. The file is the actual source of truth — the env vars are effectively dead in this setup.
- `smtp-relay` is a Postfix container that relays outbound mail to Gmail on port 587. SSP sends to it on port 25 with no auth — safe because it's internal to the Docker network.

### config.inc.local.php

```php
<?php
# ── LDAP / FreeIPA ────────────────────────────────────────────────────────────
$ldap_url    = "ldap://freeipa-server:389";
$ldap_binddn = "uid=admin,cn=users,cn=accounts,dc=asteroidea,dc=com";
$ldap_bindpw = 'Asteroidea4711$%!';
$ldap_base   = "cn=users,cn=accounts,dc=asteroidea,dc=com";
# ── Security ──────────────────────────────────────────────────────────────────
$keyphrase  = "uG/dWCYb8GVW9x9K4VrdHRP3vTD4S3DBzbllUTa0i3I=";
$use_tokens = true;
# ── Mail ──────────────────────────────────────────────────────────────────────
$mail_from     = "sadokh923@gmail.com";
$mail_sendmode = "smtp";
$smtp_host     = "smtp-relay";
$smtp_port     = 25;
$smtp_auth     = false;
$smtp_secure   = "";
$smtp_autotls  = false;
# Aliases
$mail_smtp_host   = "smtp-relay";
$mail_smtp_port   = 25;
$mail_smtp_auth   = false;
$mail_smtp_secure = "";
# ── URLs ──────────────────────────────────────────────────────────────────────
$reset_url = "http://20.0.0.154:8080";
$baseurl   = "http://20.0.0.154:8080";
# ── Debug ─────────────────────────────────────────────────────────────────────
$smtp_debug = 4;
?>
```

- `ldap://freeipa-server:389` — uses the container name instead of an IP. Docker's internal DNS resolves it as long as both containers are on `ipa-net`. More reliable than a hardcoded IP which can change on restart.
- `$use_tokens = true` + `$keyphrase` — SSP generates a one-time token, signs it with the keyphrase, and emails a reset link to the user. The keyphrase must stay constant across restarts — if it changes, any in-flight reset tokens become invalid.
- `$reset_url` and `$baseurl` — must point to the externally reachable address of SSP so that the token links in emails actually work for the user clicking them.
- `$smtp_debug = 4` — logs the full SMTP session to container logs. Useful during setup, set to `0` in production.

---

## 3. Proxmox LDAP Sync

Navigate to: **Datacenter → Realm → Add → LDAP**

### General Tab

| Field | Value |
|---|---|
| Realm | `ASTEROIDEA.COM` |
| Base Domain Name | `cn=accounts,dc=asteroidea,dc=com` |
| User Attribute Name | `uid` |
| Server | `ipa.asteroidea.com` |
| Fallback Server | *(empty)* |
| Port | `389` |
| Mode | `Default (LDAP)` |
| Verify Certificate | `none` |
| Require TFA | *(unchecked)* |

> **Note:** The Server field must be resolvable from the Proxmox host. If DNS isn't configured, use the host IP directly. Docker container names are not resolvable outside the Docker network.

### Sync Tab

| Field | Value |
|---|---|
| Bind User | `uid=admin,cn=users,cn=accounts,dc=asteroidea,dc=com` |
| Bind Password | `<ADMIN_PASSWORD>` |
| E-Mail attribute | `mail` |
| Groupname attr. | `cn` |
| Scope | `Users and Groups` |
| User classes | `inetOrgPerson, posixAccount` |
| Group classes | `groupOfNames, group, posixGroup` |
| User Filter | `(objectClass=posixAccount)` |
| Group Filter | `(&(objectClass=groupOfNames)(cn=*))` |
| Enable new users | `Yes (Default)` |

- `uid` is the login attribute in FreeIPA — not `sAMAccountName` which is Active Directory only.
- `User Filter: (objectClass=posixAccount)` — limits the sync to real user accounts, skipping service entries or anything else in the directory.
- `User classes` and `Group classes` tell Proxmox which objectClasses to look for when identifying users and groups in LDAP.

### Remove Vanished Options

| Option | State |
|---|---|
| ACL | ✅ Enabled |
| Entry | ✅ Enabled |
| Properties | ✅ Enabled |

If a user is deleted from FreeIPA, these ensure their Proxmox entry, permissions, and attributes are cleaned up on the next sync — otherwise stale entries accumulate.

### Running the Sync

```
Datacenter → Realm → select ASTEROIDEA.COM → Sync
```

Synced users appear under **Datacenter → Users** with the suffix `@ASTEROIDEA.COM`. Syncing does not grant any access — you still need to assign roles explicitly:

```
Datacenter → Permissions → Add → Group Permission
  Path:   /
  Group:  <group-name>@ASTEROIDEA.COM
  Role:   PVEAdmin
```
