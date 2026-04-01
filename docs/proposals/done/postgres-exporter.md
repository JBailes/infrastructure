# PostgreSQL Observability via postgres_exporter

## Problem

The Prometheus scrape config in `17-setup-obs.sh` references `postgres_exporter` on port 9187 for all three database hosts, but the exporter is never installed. No PostgreSQL metrics are being collected.

## Design

### What is postgres_exporter

[postgres_exporter](https://github.com/prometheus-community/postgres_exporter) is the standard Prometheus exporter for PostgreSQL. It connects to the local database and exposes metrics on an HTTP endpoint (`:9187`), including:

- Connection counts (active, idle, waiting)
- Transaction rates
- Table/index sizes and bloat
- Replication lag
- Lock contention
- Cache hit ratios
- Query durations (via `pg_stat_statements` if enabled)

### Hosts

Install on all database hosts:

| Host | IP | Databases |
|------|----|-----------|
| spire-db | 10.0.0.202 | spire |
| wol-accounts-db | 10.0.0.206 | wol_accounts |
| wol-world-db-prod | 10.0.0.213 | wol_world |
| wol-world-db-test | 10.0.0.218 | wol_world |

### Implementation

Add a shared function `install_postgres_exporter()` to `bootstrap/lib/common.sh` that:

1. Downloads the latest `postgres_exporter` binary from GitHub releases
2. Creates a `postgres_exporter` system user
3. Writes a systemd service unit that connects to the local PostgreSQL via peer auth
4. Opens port 9187 on the firewall (private network only)
5. Enables and starts the service

Each DB bootstrap script (02-setup-spire-db.sh, 02-setup-wol-accounts-db.sh, prod/12-setup-wol-world-db-prod.sh, test/12-setup-wol-world-db-test.sh) calls `install_postgres_exporter` after PostgreSQL is configured.

### Authentication

`postgres_exporter` connects to PostgreSQL locally. Two options:

**Option A: Peer auth (simplest)** - The exporter runs as a dedicated `postgres_exporter` system user. PostgreSQL `pg_hba.conf` gets a peer auth line for this user mapped to a read-only monitoring role.

**Option B: Password auth via env var** - A monitoring password is generated and stored in a file readable only by the exporter user.

Recommendation: Option A (peer auth). No passwords to manage.

### PostgreSQL monitoring role

Each DB host gets a `monitoring` role with read-only access to `pg_stat_*` views:

```sql
CREATE ROLE monitoring WITH LOGIN;
GRANT pg_monitor TO monitoring;
```

The `pg_monitor` predefined role (PostgreSQL 10+) grants read access to all statistics views.

### Firewall

Port 9187 is opened only to the private network (obs scrapes from 10.0.0.100):

```bash
ufw allow from 10.0.0.0/20 to any port 9187 proto tcp
```

## Affected Files

- `infrastructure/bootstrap/lib/common.sh`: `install_postgres_exporter()` function
- `infrastructure/bootstrap/02-setup-spire-db.sh`: call `install_postgres_exporter`, add monitoring role
- `infrastructure/bootstrap/02-setup-wol-accounts-db.sh`: call `install_postgres_exporter`, add monitoring role
- `infrastructure/bootstrap/prod/12-setup-wol-world-db-prod.sh`: call `install_postgres_exporter`, add monitoring role
- `infrastructure/bootstrap/test/12-setup-wol-world-db-test.sh`: call `install_postgres_exporter`, add monitoring role
- `infrastructure/bootstrap/12-setup-wol-world-db.sh`: add monitoring role to base template

## Trade-offs

- Adds a binary download (postgres_exporter) to each DB host during bootstrap
- Minimal resource usage (single Go binary, ~15 MB RSS)
- Peer auth avoids password management but requires a system user matching the PostgreSQL role name
