# Organizr + Traefik iframe Portal Setup

## Architecture Example

```
                        ┌─────────────────────────┐
                        │        Browser          │
                        │  organizr.home.lab       │
                        └────────────┬────────────┘
                                     │
                     ┌───────────────▼──────────────┐
                     │         Internal DNS          │
                     │    *.home.lab → Traefik IP    │
                     └───────────────┬──────────────┘
                                     │ HTTP :80
                     ┌───────────────▼──────────────┐
                     │            Traefik            │
                     │  Routes by hostname           │
                     │  Strips X-Frame-Options       │
                     └──┬────┬────┬────┬────┬───────┘
                        │    │    │    │    │
              ┌─────────┘    │    │    │    └──────────┐
              │         ┌────┘    └────┐               │
              ▼         ▼             ▼                ▼         
         ┌─────────┐ ┌────────┐ ┌──────────┐ ┌──────────┐ 
         │ Organizr│ │Grafana │ │Semaphore │ │   BBS    │ 
         └────┬────┘ └────────┘ └──────────┘ └──────────┘ 
              │
              │  iframes all services (same *.home.lab domain)
              │
   ┌──────────▼───────────────────────────────────────────────────┐
   │                  Organizr iframe portal                       │
   │   [ Grafana ] [ Semaphore ] [ BBS ] [ FreeIPA ]              │
   │   Cookies work — all apps share the same parent domain        │
   └───────────────────────────────────────────────────────────────┘
```

---

## Overview

This document covers setting up a self-hosted dashboard (Organizr) that embeds internal apps via iframes without cross-origin cookie issues.

### Problem

Browsers enforce the `SameSite` cookie policy. When an app is embedded in an iframe from a different origin (different IP or port), the browser blocks cookies on subsequent requests. This causes login loops in embedded apps like Semaphore, Borg Backup Server, Grafana, and FreeIPA.

### Solution

- All apps served under the same parent domain (e.g. `*.home.lab`) via Traefik
- DNS resolves `*.home.lab` to the Traefik VM for all machines on the network
- Traefik strips `X-Frame-Options` and `Content-Security-Policy` headers that block iframes

---

## Step 1 — Deploy Traefik

Traefik acts as a single entry point for all services, routing by hostname on port 80.

### docker-compose.yml

```yaml
services:
  traefik:
    image: traefik:v3.0
    container_name: traefik
    restart: unless-stopped
    ports:
      - "80:80"
      - "8888:8888"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    command:
      - "--api.dashboard=true"
      - "--api.insecure=true"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.dashboard.address=:8888"
      - "--providers.file.filename=/dynamic.yml"
      - "--log.level=INFO"
    configs:
      - source: traefik_dynamic
        target: /dynamic.yml

configs:
  traefik_dynamic:
    content: |
      http:
        routers:
          grafana:
            entryPoints: [web]
            rule: "Host(`grafana.home.lab`)"
            service: grafana
            middlewares: [strip-xframe]
          semaphore:
            entryPoints: [web]
            rule: "Host(`semaphore.home.lab`)"
            service: semaphore
            middlewares: [strip-xframe]
          bbs:
            entryPoints: [web]
            rule: "Host(`bbs.home.lab`)"
            service: bbs
            middlewares: [strip-xframe]
          organizr:
            entryPoints: [web]
            rule: "Host(`organizr.home.lab`)"
            service: organizr
          freeipa:
            entryPoints: [web]
            rule: "Host(`freeipa.home.lab`)"
            service: freeipa
            middlewares: [strip-xframe]
        services:
          grafana:
            loadBalancer:
              servers:
                - url: "http://<grafana-ip>:<port>"
          semaphore:
            loadBalancer:
              servers:
                - url: "http://<semaphore-ip>:<port>"
          bbs:
            loadBalancer:
              servers:
                - url: "http://<bbs-ip>:<port>"
          organizr:
            loadBalancer:
              servers:
                - url: "http://<organizr-ip>:<port>"
          freeipa:
            loadBalancer:
              serversTransport: insecure
              servers:
                - url: "https://<freeipa-ip>"
        middlewares:
          strip-xframe:
            headers:
              customResponseHeaders:
                X-Frame-Options: ""
                Content-Security-Policy: ""
        serversTransports:
          insecure:
            insecureSkipVerify: true
```




---

## Step 2 — Configure DNS

Add a wildcard DNS record pointing all `*.home.lab` hostnames to the Traefik VM. This can be done in any internal DNS server (FreeIPA, opnSense, Pi-hole, etc.):

```
*.home.lab  →  <traefik-vm-ip>
```

Every machine using the internal DNS server will resolve all `*.home.lab` hostnames to Traefik automatically — no hosts file changes needed on individual machines.

For a quick test on a single machine, add to `/etc/hosts` (Linux/Mac) or `C:\Windows\System32\drivers\etc\hosts` (Windows):

```
<traefik-ip>  organizr.home.lab grafana.home.lab semaphore.home.lab bbs.home.lab freeipa.home.lab
```

---

## Step 3 — Deploy Organizr

```yaml
services:
  organizr:
    image: organizr/organizr:latest
    container_name: organizr
    restart: unless-stopped
    ports:
      - "8085:80"
    volumes:
      - ./organizr-config:/config
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Africa/Tunis
      - fpm="false"
```

```bash
docker compose up -d
```

---

## Step 4 — Enable Grafana iframe Embedding

By default Grafana blocks iframes. Add to its environment variables:

```yaml
environment:
  - GF_SECURITY_ALLOW_EMBEDDING=true
  - GF_SECURITY_COOKIE_SAMESITE=disabled
```

```bash
docker compose restart grafana
```

---

## Step 5 — Configure Organizr Tabs

Access Organizr at `http://organizr.home.lab` (must use the hostname, not the IP).

**Settings → Tab Editor → Add Tab**

| Field | Value |
|---|---|
| Tab URL | `http://<service>.home.lab` |
| Tab Local URL | `http://<service>.home.lab` |
| Ping URL | leave empty |
| Type | iFrame |

Example tab URLs:
- `http://grafana.home.lab`
- `http://semaphore.home.lab`
- `http://bbs.home.lab`
- `http://freeipa.home.lab`

> **Important:** Always access Organizr via its hostname (`http://organizr.home.lab`), never via IP. If Organizr is accessed via IP while apps are on `*.home.lab`, the browser still sees a cross-origin mismatch and blocks cookies.

---

## Why This Works

The browser's `SameSite` cookie policy allows cookies to be shared freely when the parent page and the iframed app share the same parent domain (`home.lab`). By routing everything through Traefik under `*.home.lab`, all apps are treated as same-site by the browser, eliminating login loops inside iframes.

Traefik also strips `X-Frame-Options` and `Content-Security-Policy` headers that would otherwise prevent apps from loading inside iframes at all.


