# Docker Container Firewall with UFW

## Table of Contents
- [Overview](#overview)
- [The Problem](#the-problem)
- [Installation](#1-install-ufw-docker)
- [Enable UFW](#2-enable-ufw)
- [Restrict Access by IP](#3-allow-only-a-specific-ip-to-access-the-container)
- [Verify](#4-verify)

---

## Overview

By default, Docker bypasses UFW firewall rules by directly modifying `iptables`. This means even if UFW is blocking a port, Docker can still expose it to the world. **ufw-docker** fixes this by injecting rules into the `DOCKER-USER` iptables chain, which is processed before Docker's own rules.

---

## The Problem

```
Without ufw-docker:
  UFW blocks port 80  ──►  Docker bypasses UFW  ──►  Port 80 still publicly accessible ❌

With ufw-docker:
  UFW blocks port 80  ──►  DOCKER-USER chain enforced  ──►  Port 80 blocked ✅
```

---

## 1. Install ufw-docker

Download the `ufw-docker` helper script, make it executable, and patch the UFW rules:

```bash
sudo wget -O /usr/local/bin/ufw-docker \
  https://github.com/chaifeng/ufw-docker/raw/master/ufw-docker

sudo chmod +x /usr/local/bin/ufw-docker

sudo ufw-docker install

sudo systemctl restart ufw
sudo systemctl restart docker
```

> 💡 `ufw-docker install` modifies `/etc/ufw/after.rules` to add the `DOCKER-USER` chain rules. You only need to run this once per server.

---

## 2. Enable UFW

Set the default policy to block all incoming traffic:

```bash
sudo ufw enable
sudo ufw default deny incoming
```

> ⚠️ **Warning:** Run this on a server you have physical or out-of-band access to, or make sure port 22 (SSH) is already allowed before enabling UFW, otherwise you may lock yourself out.
>
> To allow SSH before enabling:
> ```bash
> sudo ufw allow 22/tcp
> ```

---

## 3. Allow Only a Specific IP to Access the Container

Once your container is running with a mapped port, get its internal IP:

```bash
sudo docker inspect <container-name> | grep '"IPAddress"'
```

Expected output:
```
"IPAddress": "172.17.0.2",
```

Then add a forwarding rule scoped to the IP you want to allow. Note that the rule must target the container's **internal port**, not the host port:

```bash
sudo ufw route allow proto tcp from 20.0.0.98 to 172.17.0.2 port 80
```

| Part | Value | Meaning |
|------|-------|---------|
| `proto tcp` | `tcp` | TCP traffic only |
| `from` | `20.0.0.98` | Only this source IP is allowed |
| `to` | `172.17.0.2` | The container's internal IP |
| `port` | `80` | The container's internal port |

---

## 4. Verify

Check that the rule shows up in UFW:

```bash
sudo ufw status verbose
```

Expected output:
```
To                         Action      From
--                         ------      ----
172.17.0.2 80/tcp          ALLOW FWD   20.0.0.98
```

Then confirm it's present in the `DOCKER-USER` iptables chain:

```bash
sudo iptables -L DOCKER-USER -n -v
```

Expected output:
```
Chain DOCKER-USER (1 references)
 pkts bytes target     prot opt in     out     source               destination
    0     0 ACCEPT     tcp  --  *      *       20.0.0.98            172.17.0.2           tcp dpt:80
    0     0 RETURN     all  --  *      *       0.0.0.0/0            0.0.0.0/0
```

> 💡 The `RETURN` line means all other traffic falls through to Docker's default rules — ufw-docker inserts a `DROP` earlier in the chain to block unauthorized access.
