# FreeIPA + Self-Service Password + Proxmox LDAP Sync

---

## 1. FreeIPA Server

Deployed as a Docker container using the official `freeipa/freeipa-server:almalinux-10` image.

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

- `--privileged` is required because FreeIPA needs access to system-level kernel features (e.g. systemd, network namespaces).
- `/opt/freeipa-data` is mounted to persist all FreeIPA data (LDAP database, certs, Kerberos keytabs) across container restarts.
- `--no-ntp` disables the built-in NTP setup since the host already manages time sync.
- Ports `88` and `464` (both TCP and UDP) are for Kerberos authentication and password change operations.
- The Kerberos realm `ASTEROIDEA.COM` must be uppercase by convention.

---

## 2. Self-Service Password Portal

SSP allows users to reset their FreeIPA password via a web interface without admin intervention. It communicates with FreeIPA over LDAP and sends reset tokens by email through a Postfix relay.

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

- The `ipa-net` network is declared as `external: true` — it must already exist on the host (`docker network create ipa-net`) and is shared with the `freeipa-server` container so that SSP can reach it by container name.
- The environment variables in the SSP service are **overridden by the mounted PHP config file**. The PHP file is the actual source of truth for LDAP and mail settings.
- `smtp-relay` acts as a local Postfix relay that forwards outbound emails to Gmail's SMTP server on port 587 using app credentials. SSP talks to it on port 25 with no authentication (internal network only).

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

- `$ldap_url` uses the container name `freeipa-server` — this works because both containers are on the same `ipa-net` Docker network.
- `$use_tokens = true` enables email-based reset tokens. The user receives a link, clicks it, and sets a new password without admin involvement.
- `$keyphrase` is used to sign/encrypt the reset tokens. It must stay constant across container restarts.
- `$smtp_debug = 4` logs full SMTP session output — useful during initial setup, should be set to `0` in production.
- `$reset_url` and `$baseurl` must point to the externally reachable address of the SSP container so that token links in emails work correctly.

---

## 3. Proxmox LDAP Sync

Proxmox supports LDAP-based authentication and user/group sync natively. Once configured, FreeIPA users can log into the Proxmox web UI using their LDAP credentials.

Navigate to: **Datacenter → Realm → Add → LDAP**

### General Tab

| Field | Value |
|---|---|
| Realm | `ASTEROIDEA.COM` |
| Base Domain Name | `dc=asteroidea,dc=com` |
| User Attribute Name | `uid` |
| Server | `ipa.asteroidea.com` |
| Fallback Server | *(empty)* |
| Port | `389` |
| Mode | `Default (LDAP)` |
| Verify Certificate | `none` |
| Require TFA | *(unchecked)* |

> **Note:** The Server field must be resolvable from the Proxmox host. If DNS is not configured, use the host IP directly. Docker container names are not resolvable outside the Docker network.

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

### Remove Vanished Options

| Option | State |
|---|---|
| ACL | ✅ Enabled |
| Entry | ✅ Enabled |
| Properties | ✅ Enabled |

These options ensure that when a user or group is removed from FreeIPA, their corresponding Proxmox entries and permissions are cleaned up automatically on the next sync.

### Running the Sync

After saving the realm configuration, click **Sync** from:

```
Datacenter → Realm → select ASTEROIDEA.COM → Sync
```

Synced users will appear under **Datacenter → Users** with the suffix `@ASTEROIDEA.COM`.

To grant a FreeIPA group access to Proxmox resources:

```
Datacenter → Permissions → Add → Group Permission
  Path:   /
  Group:  <group-name>@ASTEROIDEA.COM
  Role:   PVEAdmin
```
