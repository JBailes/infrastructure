# ACK! MUD Network

Isolated network for legacy ACK! MUD game servers. Runs on its own Proxmox bridge (`vmbr2`, 10.1.0.0/24), separate from the home LAN services.

Hosts are referred to by CTID and hostname. Resolve current addresses with `pct list` on the Proxmox host.

## Quick Start

```bash
./bootstrap/pve-setup-ack.sh
```

This creates the bridge, all containers, bootstraps the gateway and MUD servers, and deploys Promtail to all hosts for log shipping.

## Hosts

| CTID | Hostname | Role |
|------|----------|------|
| CT 240 | `ack-gateway` | NAT gateway, DNS, port forwarding (:8890-8895). Dual-homed on vmbr0 + vmbr2. |
| CT 241 | `acktng` | ACK!TNG MUD server |
| CT 242 | `ack431` | ACK! 4.3.1 MUD server |
| CT 243 | `ack42` | ACK! 4.2 MUD server |
| CT 244 | `ack41` | ACK! 4.1 MUD server |
| CT 245 | `assault30` | Assault 3.0 MUD server |
| CT 246 | `ack-db` | PostgreSQL database (acktng) |
| CT 247 | `ack-web` | ACK web app (ackmud.com) |
| CT 248 | `tng-ai` | NPC dialogue AI (Python/FastAPI/Groq) |
| CT 249 | `tngdb` | Read-only game content API (Python/FastAPI) |
| CT 250 | `ackfuss` | ACK!FUSS 4.4.1 MUD server |

### Shared services (managed by homelab, dual-homed)

| CTID | Hostname | Role |
|------|----------|------|
| CT 103 | `apt-cache` | Package cache (apt-cacher-ng :3142) |
| CT 104 | `obs` | Observability (Loki :3100, Prometheus :9090) |
| CT 105 | `nginx-proxy` | TLS termination and reverse proxy for `ackmud.com` |
| CT 109 | `deploy` | GitHub Actions deployment target |

## Network

- **Bridge**: `vmbr2` (10.1.0.0/24, no physical interface, isolated)
- **Gateway**: CT 240 `ack-gateway` (dual-homed, NAT + DNS + port forwarding)
- **Isolation**: ACK hosts cannot reach home LAN services directly
- **Shared services**: CT 103 `apt-cache`, CT 104 `obs`, CT 105 `nginx-proxy`, and CT 109 `deploy` are dual-homed on vmbr0 and vmbr2

> These shared hosts were previously tri-homed onto the WOL network (`vmbr1`). WOL is decommissioned and those interfaces are gone.

## Database

ACK MUD servers connect to a PostgreSQL database via libpq. The connection is configured in `data/db.conf` (a PostgreSQL connection string). The database holds all game world data (~30 tables), player records, and the help system.

**Current state:** database host CT 246 `ack-db` runs on the ACK network. MUD servers connect via `data/db.conf` pointing at it. The postgres_exporter on `:9187` ships metrics to `obs`. See `docs/proposals/done/ack-database-host.md` for migration details from the legacy host.

## Observability

All ACK hosts run Promtail, shipping logs to CT 104 `obs` on :3100 (Loki tenant: `ack`). Promtail is deployed automatically by `pve-setup-ack.sh` (phase 4) if obs is reachable, or manually via `bootstrap/02-setup-promtail.sh`.

Logs are viewable in Grafana on CT 104 `obs` under the **Loki (ACK)** datasource with query `{host!=""}`.

## ACK Website (`ackmud.com`)

The ACK web host runs on CT 247 `ack-web`. It serves `ackmud.com` from the `ackmudhistoricalarchive/web` repo on port 5000. TLS termination is handled by CT 105 `nginx-proxy`, which reaches `ack-web` over the ACK network. The old `aha.ackmud.com` subdomain redirects to `ackmud.com`.

The app preserves the legacy ACK web surface: `/api/who`, `/api/gsgp`, and `/api/reference/*`, backed by the live ACKTNG game host (CT 241 `acktng` on :8080) and a local clone of the `acktng` data tree for help, shelp, and lore files.

## Services

All MUD servers run under systemd (`mud.service`), created by the bootstrap. They start automatically on container boot.

| Host | Service | Unit | Port |
|------|---------|------|------|
| CT 241 `acktng` | ACK!TNG MUD | mud.service | :8890 |
| CT 242 `ack431` | ACK! 4.3.1 MUD | mud.service | :4000 |
| CT 243 `ack42` | ACK! 4.2 MUD | mud.service | :4000 |
| CT 244 `ack41` | ACK! 4.1 MUD | mud.service | :4000 |
| CT 245 `assault30` | Assault 3.0 MUD | mud.service | :4000 |
| CT 250 `ackfuss` | ACK!FUSS 4.4.1 MUD | mud.service | :4000 |
| CT 248 `tng-ai` | NPC dialogue AI | tng-ai.service | :8000 |
| CT 249 `tngdb` | Game content API | tngdb.service | :8000 |
| CT 247 `ack-web` | ACK website | ack-web.service | :5000 |

## Connecting to a MUD

Game clients connect to CT 240 `ack-gateway` on its LAN interface, on the appropriate port. Resolve the address with `pct config 240` on the Proxmox host.

| MUD | Port |
|-----|------|
| ACK!TNG | 8890 |
| ACK! 4.3.1 | 8891 |
| ACK! 4.2 | 8892 |
| ACK! 4.1 | 8893 |
| Assault 3.0 | 8894 |
| ACK!FUSS | 8895 |

```bash
telnet <ack-gateway> 8890
```

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
| `04-setup-ack-web.sh` | ACK web app (`ack-web`, node service on :5000) |
| `05-setup-tng-ai.sh` | NPC dialogue AI (Python/FastAPI/Groq on :8000) |
| `06-setup-tngdb.sh` | Read-only game content API (Python/FastAPI on :8000) |

## Diagrams

See [diagrams.md](diagrams.md).
