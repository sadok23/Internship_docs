# Metrics Monitoring with Prometheus

## Table of Contents
- [Overview](#overview)
- [Architecture](#architecture)
- [Monitoring VM Setup](#1-monitoring-vm-setup)
- [Prometheus Config](#2-prometheus-config)
- [Blackbox Config](#3-blackbox-config)
- [Linking Prometheus with Grafana](#4-linking-prometheus-with-grafana)
- [Adding Dashboards to Grafana](#5-adding-dashboards-to-grafana)

---

## Overview

This guide covers setting up metrics monitoring using **Prometheus**, **Blackbox Exporter**, **Pushgateway**, and **Grafana**.

| Component | Port | Role |
|-----------|------|------|
| **Prometheus** | `9090` | Scrapes and stores metrics from all targets |
| **Blackbox Exporter** | `9115` | Probes endpoints via ICMP, HTTP, and TCP — used for host pings, container health checks, and SSL checks |
| **Pushgateway** | `9091` | Receives pushed metrics from short-lived jobs (e.g. heartbeats, cron jobs) |
| **Grafana** | `3000` | Connects to Prometheus as a data source and displays metrics in dashboards |

---

## Architecture

```
Docker Server #1        Docker Server #2        Docker Server #3
 20.0.0.132              20.0.0.167              20.0.0.162
┌────────────────┐      ┌────────────────┐      ┌────────────────┐
│ containers     │      │ containers     │      │ containers     │
│ :8000/:8001/   │      │ :8000/:8001/   │      │ :8000/:8001/   │
│ :8002          │      │ :8002          │      │ :8002          │
│ SSL :8443      │      │ SSL :8443      │      │ SSL :8443      │
└───────┬────────┘      └───────┬────────┘      └───────┬────────┘
        │                       │                       │
        └───────────────────────┼───────────────────────┘
                                │  (scrape via Blackbox)
                   ┌────────────▼────────────┐
                   │      Monitoring VM      │
                   │  ┌──────────────────┐   │
                   │  │   Prometheus     │   │
                   │  │   :9090          │   │
                   │  └──────────────────┘   │
                   │  ┌──────────────────┐   │
                   │  │ Blackbox Exporter│   │
                   │  │   :9115          │   │
                   │  └──────────────────┘   │
                   │  ┌──────────────────┐   │
                   │  │  Pushgateway     │   │
                   │  │   :9091          │   │
                   │  └──────────────────┘   │
                   │  ┌──────────────────┐   │
                   │  │    Grafana       │   │
                   │  │   :3000          │   │
                   │  └──────────────────┘   │
                   └─────────────────────────┘
```

---

## 1. Monitoring VM Setup

Create a `docker-compose.yml` on the monitoring VM:

```yaml
version: "3.8"
services:
  loki:
    restart: unless-stopped
    image: grafana/loki:latest
    ports:
      - "3100:3100"
    volumes:
      - ./loki-config.yml:/etc/loki/local-config.yaml
      - loki-data:/loki
    command: -config.file=/etc/loki/local-config.yaml

  prometheus:
    restart: unless-stopped
    image: prom/prometheus:latest
    ports:
      - "9090:9090"
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml
      - prometheus-data:/prometheus
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --storage.tsdb.path=/prometheus
      - --web.enable-lifecycle
      - --web.enable-remote-write-receiver
      - --storage.tsdb.retention.time=30d

  blackbox:
    restart: unless-stopped
    image: prom/blackbox-exporter:latest
    ports:
      - "9115:9115"
    volumes:
      - ./blackbox.yml:/etc/blackbox/blackbox.yml
    command: --config.file=/etc/blackbox/blackbox.yml
    cap_add:
      - NET_RAW

  pushgateway:
    restart: unless-stopped
    image: prom/pushgateway:latest
    ports:
      - "9091:9091"
    command:
      - --push.disable-consistency-check

  grafana:
    restart: unless-stopped
    image: grafana/grafana:latest
    ports:
      - "3000:3000"
    volumes:
      - grafana-data:/var/lib/grafana
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=admin
      - GF_USERS_ALLOW_SIGN_UP=false
      - GF_SMTP_ENABLED=true
      - GF_SMTP_HOST=smtp.gmail.com:587
      - GF_SMTP_USER=you@gmail.com
      - GF_SMTP_PASSWORD=your_app_password
      - GF_SMTP_FROM_ADDRESS=you@gmail.com
      - GF_SMTP_FROM_NAME=Grafana Alerts
    depends_on:
      - prometheus
      - loki
      - blackbox
      - pushgateway

volumes:
  loki-data:
  grafana-data:
  prometheus-data:
```

> 💡 **Note:** `--web.enable-lifecycle` allows config reloads via API (`POST /-/reload`) without restarting the container. `--storage.tsdb.retention.time=30d` keeps 30 days of metrics before auto-deletion.

> ⚠️ **Note:** `NET_RAW` capability is required by Blackbox Exporter to send ICMP (ping) probes.

---

## 2. Prometheus Config

Create `prometheus.yml` in the same directory. This file defines what Prometheus scrapes and how often.

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  # ==============================
  #  HOST HEALTH CHECKS (ICMP)
  # ==============================
  - job_name: "hosts"
    metrics_path: /probe
    params:
      module: [icmp]
    static_configs:
      - targets: ["20.0.0.132"]
        labels:
          name: "host-1"
      - targets: ["20.0.0.167"]
        labels:
          name: "host-2"
      - targets: ["20.0.0.162"]
        labels:
          name: "host-3"
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: blackbox:9115
      - source_labels: [name]
        target_label: instance

  # ==============================
  #  CONTAINER PROBES (HTTP)
  # ==============================
  - job_name: "containers"
    metrics_path: /probe
    params:
      module: [http_2xx]
    static_configs:
      - targets: ["http://20.0.0.132:8000"]
        labels:
          name: "host-1-c1"
      - targets: ["http://20.0.0.132:8001"]
        labels:
          name: "host-1-c2"
      - targets: ["http://20.0.0.132:8002"]
        labels:
          name: "host-1-c3"
      - targets: ["http://20.0.0.167:8000"]
        labels:
          name: "host-2-c1"
      - targets: ["http://20.0.0.167:8001"]
        labels:
          name: "host-2-c2"
      - targets: ["http://20.0.0.167:8002"]
        labels:
          name: "host-2-c3"
      - targets: ["http://20.0.0.162:8000"]
        labels:
          name: "host-3-c1"
      - targets: ["http://20.0.0.162:8001"]
        labels:
          name: "host-3-c2"
      - targets: ["http://20.0.0.162:8002"]
        labels:
          name: "host-3-c3"
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: blackbox:9115
      - source_labels: [name]
        target_label: instance

  # ==============================
  #  SSL EXPIRY CHECKS
  # ==============================
  - job_name: "ssl"
    metrics_path: /probe
    params:
      module: [tls_connect]
    static_configs:
      - targets: ["20.0.0.132:8443"]
        labels:
          name: "host-1-ssl"
      - targets: ["20.0.0.167:8443"]
        labels:
          name: "host-2-ssl"
      - targets: ["20.0.0.162:8443"]
        labels:
          name: "host-3-ssl"
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: blackbox:9115
      - source_labels: [name]
        target_label: instance

  # ==============================
  #  PUSHGATEWAY (HEARTBEATS)
  # ==============================
  - job_name: "heartbeat"
    honor_labels: true
    scrape_interval: 15s
    static_configs:
      - targets: ["pushgateway:9091"]
```

### Scrape Jobs Summary

| Job | Module | What it checks |
|-----|--------|----------------|
| `hosts` | `icmp` | Host reachability via ping |
| `containers` | `http_2xx` | Container HTTP endpoints return `200 OK` |
| `ssl` | `tls_connect` | SSL/TLS connection on port `8443` |
| `heartbeat` | — | Metrics pushed by external jobs via Pushgateway |

> 💡 **How relabeling works:** The `relabel_configs` block rewrites the target address to point at `blackbox:9115` and passes the original target as a `__param_target` query parameter — this is how Prometheus tells Blackbox what to probe.

---

## 3. Blackbox Config

Create `blackbox.yml` in the same directory:

```yaml
modules:
  # Used by: hosts job
  icmp:
    prober: icmp
    timeout: 5s
    icmp:
      preferred_ip_protocol: ip4

  # Used by: containers job
  http_2xx:
    prober: http
    timeout: 5s
    http:
      valid_status_codes: [200]
      method: GET
      follow_redirects: true
      preferred_ip_protocol: ip4

  # Used by: ssl job (self-signed certs)
  tls_connect:
    prober: tcp
    timeout: 5s
    tcp:
      tls: true
      tls_config:
        insecure_skip_verify: true
```

> ⚠️ **Note:** `insecure_skip_verify: true` is set to allow self-signed certificates. Remove this in production if your certs are properly signed.

---

## 4. Linking Prometheus with Grafana

1. Access Grafana at `http://<host-ip>:3000`
2. Navigate to **Connections → Data Sources → Add new Data Source**
3. Select **Prometheus**
4. Set the URL to `http://prometheus:9090`
5. Click **Save and Test**

> 💡 Since Grafana and Prometheus are on the same Docker network, you can use the service name `prometheus` instead of an IP address.

---

## 5. Adding Dashboards to Grafana

The fastest way to get useful dashboards is to import pre-built ones from [grafana.com/dashboards](https://grafana.com/grafana/dashboards/).

**Steps:**
1. Find a dashboard and copy its ID
2. In Grafana, go to **Dashboards → New → Import**
3. Enter the dashboard ID and click **Load**
4. Select your Prometheus data source and click **Import**

