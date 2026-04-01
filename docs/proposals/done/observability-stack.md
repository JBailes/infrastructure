# Proposal: Observability Stack (Logging, Metrics, and Alerting)

**Status:** Active
**Date:** 2026-03-26 (revised 2026-03-27)
**Affects:** All WOL and ACK services, homelab bootstrap, Proxmox host
**Depends on:** `private-ca-and-secret-management.md` (cfssl CA for mTLS certs)

---

## Problem

Every infrastructure proposal references a monitoring stack that does not exist yet. The private-ca proposal requires SIEM integration for security events (Section 7.2), the SPIRE proposal expects Prometheus + Alertmanager for health monitoring (Section 10), and all API proposals expect `/health` polling and structured log aggregation. Logs go to stdout and stay on the host where the container runs. Metrics are not collected. Alerts are not routed anywhere. The ACK network has no observability at all.

---

## Goals

1. A dedicated observability host serving all three networks (WOL, ACK, home LAN)
2. All services push structured logs to a central collector
3. All services expose metrics scraped by a central metrics server
4. Alerts fire on defined conditions and route to the operator
5. Security events are indexed separately with 90-day retention (per private-ca Section 7.2)

---

## Non-goals

- Distributed tracing (OpenTelemetry spans). Future proposal.
- External uptime monitoring or status pages.
- Log analysis, dashboarding layout, or runbook content. Those are operational, not infrastructure.

---

## Host Specification

| Field | Value |
|-------|-------|
| Hostname | `obs` |
| CTID | 100 (static, homelab-managed) |
| Type | LXC |
| WOL IP | 10.0.0.100 (vmbr1) |
| ACK IP | 10.1.0.100 (vmbr2) |
| LAN IP | 192.168.1.100 (vmbr0) |
| Privileged | no |
| Disk | 64 GB |
| RAM | 2048 MB |
| Cores | 2 |

Tri-homed: the LAN interface serves Grafana to the operator and accepts log/metric ingestion from the Proxmox host. The WOL interface receives logs and metrics from all WOL private-network services over mTLS. The ACK interface receives logs from ACK MUD servers over TLS. No game traffic touches this host.

This host is **managed by homelab** (`homelab/bootstrap/03-setup-obs.sh`), not by the WOL orchestrator. It follows the same shared-service pattern as apt-cache: deployed before WOL and ACK services so they have an ingestion target.

This host does **not** run a SPIRE Agent or workload. It is infrastructure-only (same class as gateways, cfssl CA, DB hosts).

### Identity and certificate model

All observability mTLS uses **cfssl CA exclusively**. SPIRE is not involved. This is the same trust path as PostgreSQL client certificates, not the service-to-service SVID path.

| Certificate | Issued by | CN | SAN | Lifetime | Rotation | Purpose |
|-------------|-----------|-----|-----|----------|----------|---------|
| Loki server cert | cfssl CA | `obs` | DNS=obs, IP=10.0.0.100, IP=192.168.1.100, IP=10.1.0.100 | 24h | `enroll-host-certs.sh` on obs | TLS termination for Loki ingestion. SAN includes all three IPs. |
| Promtail client cert (per WOL host) | cfssl CA | `promtail` | | 24h | `enroll-host-certs.sh` on each host | mTLS client auth when pushing logs to Loki |
| Prometheus client cert | cfssl CA | `prometheus` | | 24h | `enroll-host-certs.sh` on obs | mTLS client auth when scraping WOL service `/metrics` endpoints |

Promtail agents on WOL hosts enroll their client cert from cfssl CA during bootstrap (step 18). The `enroll-host-certs.sh` process handles rotation. ACK hosts do not use mTLS (see Authentication model below).

---

## Stack Selection

| Component | Tool | Purpose |
|-----------|------|---------|
| Log aggregation | **Loki** | Receives structured JSON logs from all services via Promtail agents. Low resource footprint, pairs natively with Grafana. |
| Metrics | **Prometheus** | Scrapes `/metrics` endpoints on all services. Single-instance is sufficient at current scale. |
| Alerting | **Alertmanager** | Receives alerts from Prometheus rules. Routes to webhook (future: PagerDuty, Slack, email). |
| Visualization | **Grafana** | Dashboards for logs (via Loki datasource) and metrics (via Prometheus datasource). Accessible on the LAN interface. |
| Log shipping | **Promtail** | Runs on each service host as a systemd service. Tails stdout journal logs and pushes to Loki. |

All components run on the single `obs` host. Prometheus, Loki, Alertmanager, and Grafana are separate systemd services sharing the host.

---

## Log Architecture

### Log flow

```
WOL services (10.0.0.0/20):
  Service (stdout) --> systemd journal --> Promtail (local) --> mTLS --> Loki (obs:3100, eth1)

ACK MUD servers (10.1.0.0/24):
  MUD server (stdout) --> systemd journal --> Promtail (local) --> TLS --> Loki (obs:3100, eth2)

Proxmox host (192.168.0.0/23):
  Host logs --> Promtail (local) --> TLS + API key --> Loki (obs:3100, eth0)
```

1. All services log structured JSON to stdout (already required by existing proposals). ACK MUD servers log plain text.
2. `systemd` captures stdout into the journal.
3. Promtail reads the journal, adds labels (`host`, `service`, `level`), and pushes to Loki.
4. Loki stores logs with configurable retention, partitioned by tenant.

### Multi-tenancy

Loki uses `auth_enabled: true` with per-network tenants:

| Tenant | Source | Auth | Interface |
|--------|--------|------|-----------|
| `wol` | WOL Promtail agents | mTLS (cfssl CA client cert) | eth1 (10.0.0.100) |
| `ack` | ACK Promtail agents (5 MUD servers) | TLS (insecure_skip_verify) | eth2 (10.1.0.100) |
| `homelab` | LAN Promtail agents (apt-cache, vpn-gateway, bittorrent) | TLS (insecure_skip_verify) | eth0 (192.168.1.100) |
| `proxmox` | Proxmox host Promtail | TLS + API key | eth0 (192.168.1.100) |

Grafana has a separate Loki datasource provisioned for each tenant (wol, ack, homelab, proxmox) so logs are queryable independently.

### Security event separation

Promtail labels log lines containing `"severity":"security"` with an additional `stream=security` label. Loki retains the `security` stream for 90 days (per private-ca Section 7.2). Application logs are retained for 30 days. Retention is enforced by Loki's compactor.

**Promtail pipeline stage** (applied on WOL hosts only):
```yaml
pipeline_stages:
  - json:
      expressions:
        severity: severity
  - labels:
      severity:
  - match:
      selector: '{severity="security"}'
      stages:
        - labels:
            stream: security
```

**Loki retention config** (`loki.yaml`):
```yaml
limits_config:
  retention_period: 720h  # 30 days default
  per_stream_rate_limit: 3MB
compactor:
  retention_enabled: true
  retention_delete_delay: 2h
  retention_delete_worker_count: 10
overrides:
  security:
    retention_period: 2160h  # 90 days
```

### Log sanitization

Sanitization happens at the source (the service), not in the pipeline. Services must never log secret values (tokens, passwords, private keys). Promtail does not perform content transformation.

---

## Metrics Architecture

### Metric collection

```
Prometheus (obs:9090) --scrape--> Service :metrics endpoints (all networks)
```

Prometheus scrapes each service's `/metrics` endpoint. Scrape configurations:

- **WOL internal** (`job_name: wol`): scrapes over mTLS on the private network. Targets derived from inventory.
- **PostgreSQL** (`job_name: postgres`): scrapes `postgres_exporter` on DB hosts (10.0.0.202, 10.0.0.206, 10.0.0.213, 10.0.0.214, 10.0.0.218, 10.0.0.219) over mTLS.
- **SPIRE Server** (`job_name: spire-server`): scrapes 10.0.0.204:8081 over mTLS.
- **ACK** (`job_name: ack`): scrapes ACK hosts over HTTP on the ACK network. Initially empty; populated as ACK services expose `/metrics`.
- **Proxmox** (`job_name: proxmox`): scrapes `pve-exporter` at 192.168.1.253:9221. Provides VM/container CPU, memory, disk, network, and storage pool metrics.
- **External** (`job_name: external`): scrapes services on 192.168.0.0/23 over HTTPS. Targets defined in `external-targets.yml`. Labeled `network=external`.
- **Self-monitoring** (`job_name: obs-self`, `obs-loki`): scrapes local Prometheus, Alertmanager, and Loki.

### Required metrics per service

All API services (wol-accounts, wol-world) expose metrics via `prometheus-net`:

- `http_requests_total` (method, endpoint, status)
- `http_request_duration_seconds` (histogram)
- `http_requests_in_progress` (gauge)

All services additionally expose:

- Process metrics (CPU, memory, open FDs) via the runtime's default collector
- `/health` status as a metric (`up` gauge)

SPIRE Server and Agent expose their built-in Prometheus metrics endpoints. cfssl CA exposes certificate issuance and renewal metrics. PostgreSQL metrics are collected by `postgres_exporter` on each DB host.

### Cardinality guardrails

**Forbidden labels** (must never appear as metric label values):
- User IDs, account IDs, character IDs, session tokens
- Email addresses or any PII
- Request bodies, query strings, or full URL paths with variable segments
- Timestamps or unique request identifiers
- IP addresses (use aggregated network labels instead)

**Allowed labels** for `http_requests_total` and `http_request_duration_seconds`:
- `method`: HTTP method (GET, POST, PATCH, DELETE)
- `endpoint`: route template, not the resolved path (e.g., `/characters/{char_id}`)
- `status`: HTTP status code

**Histogram bucket boundaries** (seconds): `0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0`

**Cardinality budget:** Each service should produce fewer than 500 unique time series. Two levels of protection:

1. **Metric relabel rules** (`metric_relabel_configs`): drop known high-cardinality metric families before ingestion.
2. **Hard cap** (`sample_limit: 5000`): entire scrape rejected if exceeded (fail-closed).

### .NET services (wol, wol-realm)

WOL and wol-realm expose metrics via `prometheus-net`. The `/metrics` endpoint is bound to the internal interface only.

### Proxmox integration (192.168.1.253)

**Metrics:** `prometheus-pve-exporter` runs on the Proxmox host (pip venv, systemd on :9221). Authenticates to the Proxmox API with a read-only token (`prometheus@pve!metrics`, PVEAuditor role). Prometheus scrapes it as `job_name: proxmox`.

**Logs:** Promtail runs on the Proxmox host. Tails `/var/log/syslog`, `/var/log/pveproxy/access.log`, and the systemd journal. Pushes to Loki at `192.168.1.100:3100` (TLS + API key, `X-Scope-OrgID: proxmox`).

---

## Alerting

### Metric source-of-truth

| Metric | Producer | Scrape target |
|--------|----------|--------------|
| `cert_not_after_seconds` | Each .NET service via custom gauge | `job_name: wol` per-host |
| `ntp_offset_seconds` | `chrony_exporter` or custom gauge | `job_name: wol` per-host |
| `spire_agent_health` | SPIRE Agent built-in metrics | `job_name: wol` on agent hosts |
| `spire_server_health` | SPIRE Server built-in metrics | `job_name: wol` on spire-server |
| `auth_denied_total` | Each API service via custom counter | `job_name: wol` per-host |
| `pg_stat_activity_count` | `postgres_exporter` | `job_name: postgres` on DB hosts |
| `pg_settings_max_connections` | `postgres_exporter` | `job_name: postgres` on DB hosts |

### Alert rules

| Alert | Expression | For | Severity |
|-------|-----------|-----|----------|
| `ServiceDown` | `up == 0` | 30s | critical |
| `CertRenewalFailed` | `increase(cert_renewal_failures_total[5m]) > 0` | 0s | critical |
| `CertExpiringSoon` | `cert_not_after_seconds - time() < 7200` | 5m | warning |
| `ClockSkewHigh` | `abs(ntp_offset_seconds) > 15` | 1m | warning |
| `ClockSkewCritical` | `abs(ntp_offset_seconds) > 30` | 1m | critical |
| `SpireAgentUnhealthy` | `spire_agent_health != 1` | 60s | critical |
| `SpireServerUnhealthy` | `spire_server_health != 1` | 30s | critical |
| `HighErrorRate` | `sum(rate(http_requests_total{status=~"5.."}[5m])) / sum(rate(http_requests_total[5m])) > 0.05` | 5m | warning |
| `DBConnectionExhausted` | `pg_stat_activity_count / pg_settings_max_connections > 0.8` | 2m | warning |
| `DiskSpaceLow` | `node_filesystem_avail_bytes / node_filesystem_size_bytes < 0.15` | 5m | warning |
| `AuthDeniedSpike` | `rate(auth_denied_total[1m]) > 5` | 2m | warning |
| `CardinalityBudgetExceeded` | `scrape_samples_scraped > 4000` | 5m | warning |
| `DependencyDown` | `dependency_up == 0` | 30s | critical |
| `ProxmoxHostCpuHigh` | `pve_cpu_usage_ratio{id="node/pve"} > 0.9` | 5m | warning |
| `ProxmoxHostMemoryHigh` | `pve_memory_usage_bytes / pve_memory_size_bytes > 0.9` | 5m | warning |
| `ProxmoxStorageLow` | `pve_disk_usage_bytes / pve_disk_size_bytes > 0.85` | 5m | warning |
| `ProxmoxGuestDown` | `pve_up{id=~"lxc/.*|qemu/.*"} == 0` | 60s | critical |

### Alert routing

Alertmanager groups alerts by severity:
- **critical**: webhook to operator notification channel (configured post-bootstrap), repeat every 15m
- **warning**: logged and batched, repeat every 1h

---

## Deployment

### Bootstrap scripts

**`homelab/bootstrap/03-setup-obs.sh`** creates and configures the obs container (tri-homed on all three bridges). The script:

1. Creates CT 100 with eth0 (vmbr0), eth1 (vmbr1), eth2 (vmbr2)
2. Installs Loki, Promtail, Prometheus, Alertmanager, and Grafana
3. Configures Loki with retention policies and multi-tenancy
4. Configures Prometheus with scrape targets from all networks
5. Configures Alertmanager with alert rules
6. Configures Grafana with per-tenant Loki datasources and Prometheus datasource
7. Configures mTLS for WOL Loki ingestion (cfssl CA client cert verification)
8. Configures firewall (tri-homed: WOL, ACK, and LAN ingestion rules)
9. Starts all services and runs postchecks

**Prechecks:** cfssl CA reachable, gateway reachable on WOL network.

**Postchecks:** Loki ready, Prometheus healthy, Alertmanager healthy, Grafana responding on LAN interface.

### WOL Promtail deployment

**`wol/bootstrap/19-setup-promtail.sh`** runs on every WOL host (step 18 in the bootstrap sequence). Configures Promtail to push to `https://10.0.0.100:3100` over mTLS with `tenant_id: wol`.

### ACK Promtail deployment

**`homelab/ack/bootstrap/02-setup-promtail.sh`** runs on each ACK MUD server (acktng, ack431, ack42, ack41, assault30) after obs is up. Configures Promtail to push to `https://10.1.0.100:3100` over TLS with `tenant_id: ack`. No mTLS (ACK hosts do not participate in the WOL PKI).

### LAN Promtail deployment

**`homelab/bootstrap/04-setup-promtail-lan.sh`** runs on each LAN homelab host (apt-cache, vpn-gateway, bittorrent) after obs is up. Configures Promtail to push to `https://192.168.1.100:3100` over TLS with `tenant_id: homelab`. Same auth pattern as ACK and Proxmox (TLS, no mTLS).

### Proxmox host observability

**`homelab/bootstrap/09-setup-proxmox-obs.sh`** runs on the Proxmox host itself (192.168.1.253). Installs `prometheus-pve-exporter` (pip venv, systemd on :9221) and Promtail (pushes to Loki at `192.168.1.100:3100`, tenant `proxmox`). Configures firewall to allow Prometheus scrape from obs.

### postgres_exporter deployment

Installed on each DB host by the DB bootstrap scripts. Connects to the local PostgreSQL instance and exposes metrics on `:9187` (internal interface only).

### Deployment order

1. **Homelab:** `03-setup-obs.sh` (must run before WOL or ACK Promtail steps)
2. **WOL:** bootstrap proceeds normally; step 18 deploys Promtail on all WOL hosts
3. **ACK:** after ACK hosts are created, run `ack/bootstrap/02-setup-promtail.sh` on each
4. **Proxmox:** run `09-setup-proxmox-obs.sh` directly on the Proxmox host

---

## Security

### Network access

| Port | Interface | Service | Access |
|------|-----------|---------|--------|
| 3000 | eth0 (LAN) | Grafana | Operator browser access from 192.168.0.0/23. Grafana local admin auth. |
| 3100 | all three | Loki | eth1: WOL Promtail over mTLS. eth2: ACK Promtail over TLS. eth0: Proxmox/external Promtail over TLS + API key. |
| 9090 | eth0 + eth1 | Prometheus | eth1: scrapes WOL service metrics. eth0: scrapes Proxmox/external metrics. UI from 192.168.0.0/23. |
| 9090 | eth2 | Prometheus | ACK service metrics (when exposed). |
| 9093 | localhost | Alertmanager | Internal only. Prometheus pushes alerts locally. |
| 22 | eth1 | SSH | From 10.0.0.0/20 only. |

### Authentication model

**WOL (eth1, mTLS):** cfssl CA-issued client certificates, consistent with all other WOL internal communication. Promtail agents authenticate with `CN=promtail` certs. Loki verifies against the WOL root CA.

**ACK (eth2, TLS):** TLS with `insecure_skip_verify` on the client side. ACK hosts do not participate in the WOL PKI. The ACK network is physically isolated (vmbr2), so the risk of spoofed log injection is limited. ACK logs land in a separate tenant and cannot pollute WOL log data.

**External/Proxmox (eth0, TLS + API key):** Non-WOL services use TLS with Loki's `X-Scope-OrgID` header for tenant identification. No mTLS.

This three-tier auth model keeps WOL's mTLS boundary intact while allowing ACK and external services to ship logs without requiring WOL PKI enrollment.

### Grafana authentication

Local admin account (password generated during bootstrap, saved to `/etc/obs/grafana-admin-password`). Anonymous access disabled.

### No SPIRE workload

obs does not run a SPIRE Agent. It is infrastructure, not a game service. mTLS for Loki ingestion uses cfssl CA certificates (same trust path as DB connections).

---

## Changes to existing proposals

| Proposal | Change |
|----------|--------|
| `proxmox-deployment-automation.md` | Remove obs from WOL inventory (now homelab-managed). Update host count. |
| `private-ca-and-secret-management.md` | Add `CN=promtail` client cert and `CN=obs` server cert to cfssl CA provisioner scope |
| `wol-accounts-db-and-api.md` | Add `prometheus-net` NuGet package; `/metrics` endpoint on internal interface |
| `wol-world-db-and-api.md` | Same as accounts |

---

## Trade-offs

**Single host for all observability.** Loki, Prometheus, Alertmanager, and Grafana share one LXC. Appropriate at current scale (< 25 hosts). Can be split later.

**Tri-homed shared service.** obs depends on WOL gateways for DNS and outbound connectivity on vmbr1, same as apt-cache. If gateways are down, obs cannot resolve DNS, but log ingestion still works (Promtail connects by IP).

**ACK without mTLS.** ACK hosts are legacy and untrusted. TLS without client certs means a compromised ACK host could push spoofed logs, but only into the `ack` tenant. WOL log integrity is unaffected.

**Promtail on every host.** Adds ~30 MB RAM per host but avoids modifying service code. Services continue logging to stdout.

**No distributed tracing.** Deferred. Structured logs + Prometheus metrics are sufficient at current scale.

**64 GB disk.** Log retention (90 days security, 30 days application) with ~20 services at moderate log volume. Prometheus TSDB retention is 15 days. `DiskSpaceLow` alert fires at 85%.

---

## Affected files

| Location | File | Change |
|----------|------|--------|
| `homelab/bootstrap/` | `03-setup-obs.sh` | New: tri-homed obs container bootstrap |
| `homelab/bootstrap/` | `ack/bootstrap/02-setup-promtail.sh` | New: Promtail for ACK hosts (5 MUD servers) |
| `homelab/bootstrap/` | `04-setup-promtail-lan.sh` | New: Promtail for LAN homelab hosts (apt-cache, vpn-gateway, bittorrent) |
| `wol/bootstrap/` | `19-setup-promtail.sh` | Existing: WOL Promtail (pushes to 10.0.0.100) |
| `wol/bootstrap/` | `09-setup-proxmox-obs.sh` | Existing: Proxmox host observability (pushes to 192.168.1.100) |
| `wol/proxmox/` | `inventory.conf` | Remove obs from WOL inventory, add homelab-managed comment |
| `wol/bootstrap/` | `00-setup-gateway.sh` | Update dnsmasq entry: `address=/obs/10.0.0.100` |
