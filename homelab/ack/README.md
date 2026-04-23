# ACK! MUD Network

Isolated network for legacy ACK! MUD game servers. Runs on its own Proxmox bridge (`vmbr2`, 10.1.0.0/24), completely separate from the WOL infrastructure (`vmbr1`) and the home LAN services.

## Quick Start

```bash
./bootstrap/pve-setup-ack.sh
```

This creates the bridge, all containers, bootstraps the gateway and MUD servers, and deploys Promtail to all hosts for log shipping.

## Hosts

| CTID | Hostname | IP | Role |
|------|----------|----|------|
| 240 | ack-gateway | 10.1.0.240 (int), 192.168.1.240 (ext) | NAT gateway, DNS, port forwarding (:8890-8894) |
| 241 | acktng | 10.1.0.241 | ACK!TNG MUD server |
| 242 | ack431 | 10.1.0.242 | ACK! 4.3.1 MUD server |
| 243 | ack42 | 10.1.0.243 | ACK! 4.2 MUD server |
| 244 | ack41 | 10.1.0.244 | ACK! 4.1 MUD server |
| 245 | assault30 | 10.1.0.245 | Assault 3.0 MUD server |
| 246 | ack-db | 10.1.0.246 | PostgreSQL database (acktng) |
| 247 | ack-web | 10.1.0.247 | ACK web app (ackmud.com + aha.ackmud.com) |
| 248 | tng-ai | 10.1.0.248 | NPC dialogue AI (Python/FastAPI/Groq) |
| 249 | tngdb | 10.1.0.249 | Read-only game content API (Python/FastAPI) |

### Shared services (managed by homelab, tri-homed)

| CTID | Hostname | ACK IP | Role |
|------|----------|--------|------|
| 115 | apt-cache | 10.1.0.115 | Package cache (apt-cacher-ng :3142) |
| 100 | obs | 10.1.0.100 | Observability (Loki :3100, Prometheus :9090) |

## Network

- **Bridge**: `vmbr2` (10.1.0.0/24, no physical interface, isolated)
- **Gateway**: ack-gateway (dual-homed, NAT + DNS + port forwarding)
- **Isolation**: ACK hosts cannot reach WOL (vmbr1) or home LAN services directly
- **Shared services**: apt-cache (10.1.0.115) and obs (10.1.0.100) are tri-homed on vmbr0/vmbr1/vmbr2

## Database

ACK MUD servers connect to a PostgreSQL database via libpq. The connection is configured in `data/db.conf` (a PostgreSQL connection string). The database holds all game world data (~30 tables), player records, and the help system.

**Current state:** database host `ack-db` (CTID 246, 10.1.0.246) runs on the ACK network. MUD servers connect via `data/db.conf` pointing to `10.1.0.246`. The postgres_exporter on `:9187` ships metrics to obs. See `proposals/pending/ack-database-host.md` for migration details from the legacy host (192.168.1.112).

## Observability

All ACK hosts run Promtail, shipping logs to obs at 10.1.0.100:3100 (Loki tenant: `ack`). Promtail is deployed automatically by `pve-setup-ack.sh` (phase 4) if obs is reachable, or manually via `bootstrap/02-setup-promtail.sh`.

Logs are viewable in Grafana (http://192.168.1.100) under the **Loki (ACK)** datasource with query `{host!=""}`.

## ACK Websites (`aha.ackmud.com`, `ackmud.com`)

The ACK web host runs on ack-web (CT 247, 10.1.0.247). It serves both `aha.ackmud.com` and `ackmud.com` from the `ackmudhistoricalarchive/web` repo on port 5000. TLS termination is handled by nginx-proxy (10.1.0.118 on the ACK network, 192.168.1.118 on the LAN).

The app preserves the legacy ACK web surface: `/api/who`, `/api/gsgp`, and `/api/reference/*`, backed by the live ACKTNG game host (`10.1.0.241:8080`) and a local clone of the `acktng` data tree for help, shelp, and lore files.

## Services

All MUD servers run under systemd (`mud.service`), created by the bootstrap. They start automatically on container boot.

| Host | Service | Unit | Port |
|------|---------|------|------|
| acktng (CT 241) | ACK!TNG MUD | mud.service | :4000 |
| ack431 (CT 242) | ACK! 4.3.1 MUD | mud.service | :4000 |
| ack42 (CT 243) | ACK! 4.2 MUD | mud.service | :4000 |
| ack41 (CT 244) | ACK! 4.1 MUD | mud.service | :4000 |
| assault30 (CT 245) | Assault 3.0 MUD | mud.service | :4000 |
| tng-ai (CT 248) | NPC dialogue AI | tng-ai.service | :8000 |
| tngdb (CT 249) | Game content API | tngdb.service | :8000 |
| ack-web (CT 247) | AHA website | ack-web.service | :5000 |

## Connecting to a MUD

Game clients connect to `192.168.1.240` on the appropriate port:

| MUD | Port | Connect command |
|-----|------|----------------|
| ACK!TNG | 8890 | `telnet 192.168.1.240 8890` |
| ACK! 4.3.1 | 8891 | `telnet 192.168.1.240 8891` |
| ACK! 4.2 | 8892 | `telnet 192.168.1.240 8892` |
| ACK! 4.1 | 8893 | `telnet 192.168.1.240 8893` |
| Assault 3.0 | 8894 | `telnet 192.168.1.240 8894` |

## Deploying MUD source

After bootstrap, each server has build tools installed (including libpq-dev for PostgreSQL connectivity). Deploy source and build:

```bash
# Push source to a MUD server
pct push 241 /path/to/acktng/src /opt/mud/src/

# Build
pct exec 241 -- bash -c "cd /opt/mud/src && make"

# Start
pct exec 241 -- bash -c "cd /opt/mud/src && ./startup &"
```

## Bootstrap scripts

| Script | Purpose |
|--------|---------|
| `pve-setup-ack.sh` | Orchestrator: creates bridge, containers, bootstraps everything |
| `00-setup-ack-gateway.sh` | NAT gateway, DNS (dnsmasq), port forwarding |
| `01-setup-ack-mud.sh` | MUD server host (build tools, directory structure) |
| `02-setup-promtail.sh` | Promtail log shipper (deployed to all ACK hosts) |
| `03-setup-ack-db.sh` | PostgreSQL database host (acktng database, postgres_exporter) |
| `04-setup-ack-web.sh` | AHA web app (`ack-web`, node service on :5000) |
| `05-setup-tng-ai.sh` | NPC dialogue AI (Python/FastAPI/Groq on :8000) |
| `06-setup-tngdb.sh` | Read-only game content API (Python/FastAPI on :8000) |

## Diagrams

See [diagrams.md](diagrams.md).
