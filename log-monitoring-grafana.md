# Log Monitoring with Grafana

## Table of Contents
- [Overview](#overview)
- [Architecture](#architecture)
- [Monitoring VM Setup](#1-monitoring-vm-setup)
- [Docker Servers Setup](#2-docker-servers-setup)
- [Adding Dashboards to Grafana](#3-adding-dashboards-to-grafana)

---

## Overview

This guide covers setting up centralized log monitoring using **Promtail**, **Loki**, and **Grafana**.

| Component | Role |
|-----------|------|
| **Promtail** | Reads container logs, adds labels, and ships them to Loki via HTTP. Must be installed on each server. |
| **Loki** | Ingests, stores, and indexes logs based on their labels. |
| **Grafana** | Connects to Loki as a data source, queries logs using LogQL, and displays them in dashboards. |

---

## Architecture

```
Docker Server #1        Docker Server #2        Docker Server #3
┌──────────────┐        ┌──────────────┐        ┌──────────────┐
│   Promtail   │        │   Promtail   │        │   Promtail   │
└──────┬───────┘        └──────┬───────┘        └──────┬───────┘
       │                       │                       │
       └───────────────────────┼───────────────────────┘
                               │
                    ┌──────────▼──────────┐
                    │   Monitoring VM     │
                    │  ┌───────────────┐  │
                    │  │     Loki      │  │
                    │  └───────────────┘  │
                    │  ┌───────────────┐  │
                    │  │    Grafana    │  │
                    │  └───────────────┘  │
                    └─────────────────────┘
```

---

## 1. Monitoring VM Setup

### Installing Loki and Grafana

Create a `docker-compose.yml` file on the monitoring VM:

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

volumes:
  loki-data:
  grafana-data:
```

> ⚠️ **Note:** A Loki config file must be created and accessible before running the containers. Set the SMTP environment variables if you want Grafana alerts via email.

---

### Loki Config File

Create `loki-config.yml` in the same directory:

```yaml
auth_enabled: false

server:
  http_listen_port: 3100

common:
  ring:
    instance_addr: 127.0.0.1
    kvstore:
      store: inmemory
  replication_factor: 1
  path_prefix: /loki

schema_config:
  configs:
    - from: 2020-10-24
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h

storage_config:
  tsdb_shipper:
    active_index_directory: /loki/tsdb-index
    cache_location: /loki/tsdb-cache
  filesystem:
    directory: /loki/chunks

limits_config:
  reject_old_samples: true
  reject_old_samples_max_age: 168h
  ingestion_rate_mb: 10
  ingestion_burst_size_mb: 20
  retention_period: 7d

compactor:
  working_directory: /loki/compactor
  compaction_interval: 10m
  retention_enabled: true
  retention_delete_delay: 2h
  delete_request_store: filesystem
```

> 💡 **Tips:**
> - Set `retention_period` if you want automatic log deletion
> - Set `object_store` to `filesystem` when storing logs locally

---

### Linking Grafana with Loki

1. Access the Grafana UI at `http://<host-ip>:3000`
2. Navigate to **Connections → Data Sources → Add new Data Source**
3. Select **Loki**
4. Set the URL to `http://<host-ip>:3100`
5. Click **Save and Test**

---

## 2. Docker Servers Setup

### Installing Promtail

On each Docker server, create a `docker-compose.yml`:

```yaml
version: "3.8"
services:
  promtail:
    image: grafana/promtail:latest
    container_name: promtail
    user: root
    volumes:
      - /var/log:/var/log
      - /var/lib/docker/containers:/var/lib/docker/containers:ro
      - /var/run/docker.sock:/var/run/docker.sock
      - ./promtail-config.yml:/etc/promtail/config.yml
    command: -config.file=/etc/promtail/config.yml
    restart: unless-stopped
```

> ⚠️ **Note:** The Promtail config file must be created and accessible before running the container.

---

### Promtail Config File

Create `promtail-config.yml` on each Docker server:

```yaml
server:
  http_listen_port: 9080
  grpc_listen_port: 0

positions:
  filename: /tmp/positions.yaml

clients:
  - url: http://<loki-ip>:3100/loki/api/v1/push

scrape_configs:
  - job_name: docker
    docker_sd_configs:
      - host: unix:///var/run/docker.sock
        refresh_interval: 5s

    relabel_configs:
      - source_labels: ['__meta_docker_container_name']
        regex: '/(.*)'
        target_label: 'container_name'
      - source_labels: ['__meta_docker_container_image']
        target_label: 'container_image'
      - replacement: 'server-1'
        target_label: 'host'
```

> 💡 **Tips:**
> - Replace `<loki-ip>` with your monitoring VM's IP address — logs won't be sent otherwise
> - The config labels logs by `container_name`, `container_image`, and `host`
> - Add extra labels like `stack` or `network` to make log querying easier in Grafana

---

## 3. Adding Dashboards to Grafana

The fastest way to get useful dashboards is to import pre-built ones from [grafana.com/dashboards](https://grafana.com/grafana/dashboards/).

**Steps:**
1. Find a dashboard on [grafana.com/dashboards](https://grafana.com/grafana/dashboards/) and copy its ID
2. In Grafana, go to **Dashboards → New → Import**
3. Enter the dashboard ID (e.g. `13639`) and click **Load**
4. Select your Loki data source and click **Import**

> 💡 This gives you a ready-to-use dashboard with little to no manual configuration.
