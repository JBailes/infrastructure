# Proposal: ACK! Network Service Bring-Up

**Status:** Complete
**Date:** 2026-03-29
**Affects:** ACK network, homelab/ack/bootstrap/, observability, acktng

---

## Problem

The ACK! network infrastructure is fully built (gateway, containers, bootstrap scripts, Promtail), but the services themselves are not running end-to-end:

1. **MUD servers have no autostart.** The bootstrap clones source and builds, but there are no systemd units. Starting a MUD requires an SSH session and a manual `./startup &`. If the container restarts, the game is down until someone notices.
2. **tng-ai is outside the ACK network.** The NPC dialogue AI runs on CT 111 (192.168.1.111) on the home LAN. acktng routes through ack-gateway to reach it, breaking the isolation model.
3. **tngdb is outside the ACK network.** The read-only game content API runs on CT 112 (192.168.1.112), co-located with the legacy database host. It needs its own container on the ACK network.
4. **Legacy hosts to decommission.** CT 111 (tng-ai) and CT 112 (tngdb + legacy database) are LAN hosts that exist solely to serve the ACK ecosystem. Once their services are migrated to the ACK network, these containers serve no purpose and should be destroyed.
5. **No observability for application-layer services.** Promtail ships system logs, but without systemd units there are no game logs in the journal. Blackbox TCP probes are configured in the dashboard but return red because the games aren't listening yet. tng-ai and tngdb have no monitoring at all.

---

## Goals

1. All five MUD servers start automatically via systemd and survive container restarts
2. tng-ai runs on the ACK network (CT 248, 10.1.0.248), bootstrapped by script
3. tngdb runs on the ACK network (CT 249, 10.1.0.249), bootstrapped by script
4. acktng reads `TNGAI_URL` from the environment, pointing at the ACK-local tng-ai
5. All services are observable: logs in Loki, health in Prometheus, tiles on the dashboard
6. Legacy LAN hosts CT 111 and CT 112 are decommissioned and destroyed

---

## Non-Goals

- Database migration from 192.168.1.112 to ack-db. That is covered by the [ACK Database Host proposal](ack-database-host.md), which is a prerequisite for this work.
- Rewriting tng-ai or tngdb application code. Only deployment and configuration.
- TLS between ACK services. The network is isolated; plain HTTP is acceptable.
- External access to tngdb. It serves the ACK network only (ack-web proxies or queries it).

---

## Prerequisites

The [ACK Database Host proposal](ack-database-host.md) must be implemented first. MUD servers and tngdb both connect to the PostgreSQL database on ack-db (10.1.0.246). The database must be migrated and accessible before these services can start.

---

## New Hosts

### tng-ai (CT 248)

| Field | Value |
|-------|-------|
| Hostname | `tng-ai` |
| CTID | 248 |
| Type | LXC (unprivileged) |
| IP | 10.1.0.248 |
| Bridge | vmbr2 |
| Disk | 4 GB |
| RAM | 512 MB |
| Cores | 1 |

DNS entry already exists in ack-gateway dnsmasq (`address=/tng-ai/10.1.0.248`).

NPC dialogue AI service. Python/FastAPI, calls the Groq API for LLM responses. Needs outbound HTTPS to api.groq.com (routed through ack-gateway NAT). Listens on :8000.

### tngdb (CT 249)

| Field | Value |
|-------|-------|
| Hostname | `tngdb` |
| CTID | 249 |
| Type | LXC (unprivileged) |
| IP | 10.1.0.249 |
| Bridge | vmbr2 |
| Disk | 4 GB |
| RAM | 256 MB |
| Cores | 1 |

DNS entry must be added to ack-gateway dnsmasq.

Read-only game content API. Python/FastAPI/asyncpg, serves helps, shelps, lores, and skills from the acktng database. Connects to ack-db (10.1.0.246:5432) using the `ack_readonly` user. Listens on :8000.

---

## MUD Server Autostart

Each MUD server gets a systemd unit that calls its startup script. The unit runs as root (the MUD binaries bind to privileged-range ports and manage their own area/player directories under /opt/mud).

### acktng (CT 241)

acktng has a `startup` script at the repository root that builds the binary and launches on four ports. On the ACK network, the game port is 4000 (the gateway DNATs external :8890 to internal :4000). The systemd unit overrides the default port via environment variables.

```ini
[Unit]
Description=ACK!TNG MUD server
After=network.target

[Service]
Type=exec
WorkingDirectory=/opt/mud/src
Environment=PORT=4000
Environment=TLS_PORT=0
Environment=WSS_PORT=0
Environment=WS_PORT=0
ExecStart=/opt/mud/src/startup
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

TLS and WebSocket ports are set to 0 (disabled). The ACK network has no TLS certificates, and WebSocket proxying is handled by nginx-proxy connecting to ack-web, not directly to the MUD.

### Legacy MUDs (CT 242-245: ack431, ack42, ack41, assault30)

The legacy MUD binaries are simpler: they take a port number as a positional argument and run from the area directory. The bootstrap script clones each repo to `/opt/mud/src/` and builds from the Makefile.

```ini
[Unit]
Description=ACK! MUD server (MUDNAME)
After=network.target

[Service]
Type=exec
WorkingDirectory=/opt/mud/src/area
ExecStart=/opt/mud/src/src/ack 4000
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

The `WorkingDirectory` and `ExecStart` path may vary by repo (some have `src/` subdirectories, some build in the root). The bootstrap script (`01-setup-ack-mud.sh`) will create the systemd unit with the correct paths based on where the Makefile was found.

---

## tng-ai Service

### Bootstrap: `05-setup-tng-ai.sh`

1. Disable IPv6
2. Configure DNS (ack-gateway) and apt proxy (apt-cache)
3. Install Python 3, pip, venv, curl, ca-certificates
4. Clone tng-ai repo to `/opt/tng-ai`
5. Create venv, install requirements (`fastapi`, `uvicorn`, `groq`, `pydantic`, `pydantic-settings`)
6. Write `/etc/tng-ai/env` with `GROQ_API_KEY` (provided during bootstrap or left as placeholder)
7. Create systemd unit (`tng-ai.service`)
8. Firewall: :8000 from ACK network, SSH from ACK network

### Systemd Unit

```ini
[Unit]
Description=TNG AI Service (NPC dialogue)
After=network.target

[Service]
Type=exec
User=tng-ai
WorkingDirectory=/opt/tng-ai
EnvironmentFile=/etc/tng-ai/env
ExecStart=/opt/tng-ai/.venv/bin/uvicorn app.main:app --host 0.0.0.0 --port 8000
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

### Groq API Key

The bootstrap creates `/etc/tng-ai/env` with a placeholder. The key must be provided before the service can function. The health endpoint (`GET /health`) returns 200 regardless, so the blackbox probe shows green even without a valid key. The service returns 502 on chat requests if the key is invalid.

### Migration from CT 111

1. Copy the Groq API key from CT 111's environment to `/etc/tng-ai/env` on CT 248
2. Start tng-ai on CT 248, verify `curl http://10.1.0.248:8000/health`
3. Update acktng's systemd unit to set `TNGAI_URL=http://10.1.0.248:8000/v1/chat` (or use the compiled default, which already points to 10.1.0.248 per the completed tng-ai-monitoring proposal)
4. Restart acktng
5. Decommission tng-ai on CT 111

---

## tngdb Service

### Bootstrap: `06-setup-tngdb.sh`

1. Disable IPv6
2. Configure DNS (ack-gateway) and apt proxy (apt-cache)
3. Install Python 3, pip, venv, curl, ca-certificates
4. Clone tngdb repo to `/opt/tngdb`
5. Create venv, install requirements (`fastapi`, `uvicorn`, `asyncpg`)
6. Write `/etc/tngdb/env` with `DATABASE_URL=postgres://ack_readonly:<password>@10.1.0.246/acktng`
7. Create systemd unit (`tngdb.service`)
8. Firewall: :8000 from ACK network, SSH from ACK network

### Systemd Unit

```ini
[Unit]
Description=TNG DB API (read-only game content)
After=network.target

[Service]
Type=exec
User=tngdb
WorkingDirectory=/opt/tngdb
EnvironmentFile=/etc/tngdb/env
ExecStart=/opt/tngdb/.venv/bin/uvicorn api.main:app --host 0.0.0.0 --port 8000
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

### Database Credentials

The `ack_readonly` password is generated by the ack-db bootstrap and stored in `/etc/ack-db-secrets/ack_readonly_password` on ack-db. The tngdb bootstrap reads this (or it's provided as a parameter) and writes it into the `DATABASE_URL` in `/etc/tngdb/env`.

---

## Decommission Legacy LAN Hosts

Once all services are migrated and verified on the ACK network, the legacy LAN containers are destroyed.

### CT 112 (192.168.1.112)

Currently runs: tngdb API + PostgreSQL database (the `acktng` database).

After this proposal and the ack-database-host proposal are implemented:
- The database lives on ack-db (CT 246, 10.1.0.246)
- The tngdb API lives on CT 249 (10.1.0.249)
- Nothing remains on CT 112

**Decommission steps:**
1. Verify tngdb on CT 249 is serving requests and ack-web is consuming it correctly
2. Verify no other services or clients still reference 192.168.1.112
3. Stop CT 112: `pct stop 112`
4. Destroy CT 112: `pct destroy 112`

### CT 111 (192.168.1.111)

Currently runs: tng-ai service (NPC dialogue AI).

After tng-ai is migrated to CT 248 (10.1.0.248):
- acktng points at the ACK-local tng-ai
- Nothing remains on CT 111

**Decommission steps:**
1. Verify tng-ai on CT 248 is responding to health checks and chat requests
2. Verify acktng is successfully using the ACK-local tng-ai URL
3. Stop CT 111: `pct stop 111`
4. Destroy CT 111: `pct destroy 111`

### Cleanup

After both containers are destroyed:
- Remove any Prometheus scrape targets or blackbox probes referencing 192.168.1.111 or 192.168.1.112
- Remove any DNS entries or /etc/hosts references to the old IPs
- Reclaim the CTIDs (111, 112) for future use

---

## acktng TNGAI_URL

The [tng-ai monitoring proposal](../complete/tng-ai-monitoring-and-env-var.md) (complete) already updated acktng to:
- Read `TNGAI_URL` from the environment at init time, falling back to the `#define` default
- Set the `#define` default to `http://10.1.0.248:8000/v1/chat`

No code changes needed. The acktng systemd unit picks up the default URL. If tng-ai is temporarily unavailable, NPC dialogue silently fails (existing behavior).

---

## Observability

### Promtail (logs)

Already deployed to all existing ACK hosts. New hosts (CT 248, CT 249) get Promtail via the Phase 4 deployment in `pve-setup-ack.sh`, same as the rest. Once MUD servers run under systemd, their stdout/stderr flows to the journal and Promtail ships it to Loki (tenant: `ack`).

### Blackbox Probes (health checks)

**Already configured** (in `08-setup-dashboards.sh`):
- MUD servers: TCP probes on :4000 (`blackbox-tcp` job)
- tng-ai: HTTP probe on `http://10.1.0.248:8000/health` (`blackbox-http` job)

**New** (must be added):
- tngdb: HTTP probe on `http://10.1.0.249:8000/health`

tngdb does not currently have a `/health` endpoint. A minimal one must be added (returns 200 with `{"status": "ok"}`). This is a one-line FastAPI route addition, not a rewrite.

### Prometheus Scrape Targets

No changes needed. MUD servers don't expose `/metrics` endpoints (monitored via TCP probes). tng-ai and tngdb don't expose `/metrics` either (monitored via blackbox HTTP probes). ack-db's postgres_exporter and ack-web's Kestrel metrics are already in the `ack` scrape job.

### Dashboard

The **ACK Services** panel in the Service Health dashboard already queries:
- `up{job="ack"}` (ack-web, ack-db)
- `probe_success{name="tng-ai"}` (tng-ai blackbox probe)
- `probe_success{job="blackbox-tcp", name=~"acktng|ack431|ack42|ack41|assault30|ack-gateway"}` (MUD servers + gateway)

**Add** to the panel:
- `probe_success{name="tngdb"}` for the new tngdb blackbox probe

---

## Changes

| Location | File | Change |
|----------|------|--------|
| `homelab/ack/bootstrap/` | `05-setup-tng-ai.sh` | New: tng-ai host bootstrap |
| `homelab/ack/bootstrap/` | `06-setup-tngdb.sh` | New: tngdb host bootstrap |
| `homelab/ack/bootstrap/` | `01-setup-ack-mud.sh` | Add systemd unit creation for MUD servers |
| `homelab/ack/bootstrap/` | `pve-setup-ack.sh` | Add tng-ai and tngdb to HOSTS array, bootstrap in Phase 3 |
| `homelab/ack/bootstrap/` | `00-setup-ack-gateway.sh` | Add tngdb DNS entry (`address=/tngdb/10.1.0.249`) |
| `homelab/bootstrap/` | `08-setup-dashboards.sh` | Add tngdb blackbox HTTP probe target, add tngdb to ACK Services panel |
| `homelab/ack/` | `README.md` | Add tng-ai and tngdb to hosts table, document systemd units |
| `homelab/ack/` | `diagrams.md` | Add tng-ai and tngdb to topology, host reference |
| `architecture.md` | | Add tng-ai and tngdb to ACK guest summary |
| `tngdb/` | `api/main.py` | Add `GET /health` endpoint |

---

## Execution Order

Implementation follows the dependency chain:

1. **ack-database-host proposal** (prerequisite, separate PR)
   - Bootstrap ack-db, migrate data from 192.168.1.112

2. **MUD server autostart**
   - Add systemd unit creation to `01-setup-ack-mud.sh`
   - Deploy and enable on CT 241-245
   - Verify games are listening on :4000, TCP probes go green

3. **tngdb**
   - Add `/health` endpoint to tngdb application code
   - Add tngdb DNS to gateway dnsmasq
   - Add tngdb to HOSTS in orchestrator
   - Write `06-setup-tngdb.sh`
   - Bootstrap CT 249, verify `curl http://10.1.0.249:8000/health`
   - Add blackbox probe and dashboard panel

4. **tng-ai**
   - Add tng-ai to HOSTS in orchestrator
   - Write `05-setup-tng-ai.sh`
   - Bootstrap CT 248, copy Groq API key, verify health
   - Restart acktng to pick up ACK-local tng-ai URL
   - Decommission tng-ai on CT 111

5. **Decommission legacy hosts**
   - Verify all services on the ACK network are healthy
   - Stop and destroy CT 112 (database + tngdb migrated)
   - Stop and destroy CT 111 (tng-ai migrated)
   - Remove stale scrape targets, DNS entries, and references to 192.168.1.111 / 192.168.1.112

6. **Documentation**
   - Update README, diagrams, architecture

Steps 3 and 4 are independent of each other and can be done in parallel. Step 5 must wait until both 3 and 4 are verified.

---

## Trade-offs

**MUD servers run as root.** The legacy MUD binaries assume they own `/opt/mud/` and write to area, player, and log directories. Creating a dedicated service user and chowning the tree is possible but adds complexity with no security benefit (the network is isolated, the containers are unprivileged LXCs).

**tngdb gets its own container instead of co-locating on ack-web.** This uses an extra CTID and 256 MB RAM, but keeps the Python runtime isolated from the .NET stack on ack-web. Simpler to bootstrap, update, and debug independently.

**No `/metrics` endpoint for MUD servers.** The C game servers have no Prometheus client library. TCP probes on port 4000 confirm the game is accepting connections, which is the primary health signal. Game-specific telemetry (player count, tick rate) would require C instrumentation, which is out of scope.

**tngdb health endpoint is a code change.** Adding `GET /health` to tngdb is technically an application change, but it's a single route returning a static JSON response. Without it, the only monitoring option is a TCP probe, which can't distinguish "uvicorn is up but the app crashed" from "service is healthy."

**TLS disabled on acktng ports.** The systemd unit sets `TLS_PORT=0` and `WSS_PORT=0`. The ACK network has no certificate infrastructure. If TLS is needed in the future, it would be handled by nginx-proxy, not the MUD binary.

---

## Status

Pending approval.
