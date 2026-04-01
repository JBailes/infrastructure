# Grafana Health and Utilization Dashboards

## Problem

There are no Grafana dashboards. Operators have no visibility into which services are healthy or how much CPU/memory each host is consuming without SSH-ing into individual containers.

## Goals

1. A "Service Health" dashboard showing which hosts are responding to their /health endpoint (green/red status)
2. A "Host Utilization" dashboard showing CPU and memory usage per container

## Design

### Dashboard 1: Service Health

A single-stat grid showing each service as a green (up) or red (down) tile.

**Data source:** Prometheus `up` metric (already collected for scraped targets) plus blackbox_exporter HTTP probes for hosts that don't expose /metrics.

**Services already scraped by Prometheus (have `up` metric):**

| Service | Scrape job | Target |
|---------|-----------|--------|
| wol-accounts | `wol` | 10.0.0.207:8443 |
| wol-a | `wol` | 10.0.0.208:8443 |
| wol-web | `wol` | 10.0.0.209:5000 |
| wol-world-prod | `wol` | 10.0.0.211:8443 |
| wol-ai-prod | `wol` | 10.0.0.212:8443 |
| wol-realm-prod | `wol` | 10.0.0.210:8443 |
| wol-world-test | `wol` | 10.0.0.216:8443 |
| wol-ai-test | `wol` | 10.0.0.217:8443 |
| wol-realm-test | `wol` | 10.0.0.215:8443 |
| ack-web | `ack` | 10.1.0.247:5000 |
| Prometheus | `obs-self` | localhost:9090 |
| Alertmanager | `obs-self` | localhost:9093 |
| Loki | `obs-loki` | localhost:3100 |

**Services NOT scraped (need blackbox probes):**

| Service | URL to probe | Notes |
|---------|-------------|-------|
| personal-web | http://192.168.1.117:3000/ | No /health, probe / for 200 |
| nginx-proxy | http://192.168.1.118:80/ | Probe for any HTTP response |

**Approach:** Install blackbox_exporter on obs. Add a `blackbox` scrape job to Prometheus that probes the two HTTP endpoints. Dashboard queries `up` for scraped services and `probe_success` for blackbox targets.

### Dashboard 2: Host Utilization

Per-container CPU and memory panels using pve_exporter metrics (already scraped from Proxmox at 192.168.1.253:9221).

**Metrics from pve_exporter:**

| Metric | Purpose |
|--------|---------|
| `pve_cpu_usage_ratio` | CPU utilization (0-1) per guest |
| `pve_memory_usage_bytes` | Current memory usage per guest |
| `pve_memory_size_bytes` | Allocated memory per guest |

**Panels:**
- CPU usage bar gauge (all containers, sorted by usage)
- Memory usage bar gauge (all containers, % of allocated)
- Time series: CPU over time (selectable by host)
- Time series: Memory over time (selectable by host)

### Provisioning

Both dashboards will be provisioned as JSON files via Grafana's file-based provisioning, deployed by 03-setup-obs.sh. This makes them reproducible across re-deploys.

- `/etc/grafana/provisioning/dashboards/wol.yml` (dashboard provider config)
- `/var/lib/grafana/dashboards/service-health.json`
- `/var/lib/grafana/dashboards/host-utilization.json`

## Changes

| File | Change |
|------|--------|
| `homelab/bootstrap/03-setup-obs.sh` | Install blackbox_exporter, add blackbox scrape job, add dashboard provisioning, write dashboard JSON |
| `homelab/bootstrap/03-setup-obs.sh` | Add Prometheus scrape job for blackbox HTTP probes |

## Trade-offs

**blackbox_exporter for 2 targets.** Lightweight (single binary, no config needed for HTTP probes). Could skip it and just accept that personal-web and nginx-proxy don't appear on the health dashboard, but the user explicitly wants all hosts covered.

**pve_exporter for CPU/memory instead of node_exporter.** Avoids deploying node_exporter to every container. The trade-off is less granularity (no per-process, no disk I/O breakdown), but for a utilization overview dashboard it's sufficient. node_exporter can be added later if deeper metrics are needed.
