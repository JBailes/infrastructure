# Proposal: ACK Database Host and tngdb Migration

**Status:** Complete
**Date:** 2026-03-27
**Affects:** ACK network, homelab/ack/bootstrap/, observability

---

## Problem

The ACK MUD servers currently connect to a PostgreSQL database running outside the ACK network (192.168.1.112, the existing tngdb host on the home LAN). This has several issues:

1. **Network isolation violation.** ACK hosts on vmbr2 (10.1.0.0/24) must route through ack-gateway to reach a LAN database, breaking the isolation model.
2. **No observability.** The existing database has no Prometheus metrics, no postgres_exporter, and no log shipping to the obs stack.
3. **No bootstrap automation.** The database is manually provisioned. There is no bootstrap script, no automated schema migration, and no documented recovery procedure.
4. **Shared with tngdb API.** The tngdb Python API (FastAPI/asyncpg) runs on the same host and shares the database. The API is a read-only convenience layer for web clients, not a requirement for the MUD servers.

The ACK MUD servers need a PostgreSQL database on the ACK private network, bootstrapped and observable like every other database in the infrastructure.

---

## Goals

1. A dedicated PostgreSQL host on the ACK network, bootstrapped by a script
2. MUD servers connect to the database over the local ACK network (no LAN routing)
3. postgres_exporter and Promtail ship metrics and logs to obs
4. Migration path from the existing tngdb database (192.168.1.112) to the new host
5. tngdb API can optionally connect to the new host if needed

---

## Non-goals

- Rewriting the tngdb API or changing its endpoints.
- Modifying the ACK MUD server's database code (db_conn.c, db_worker.c). It uses standard libpq connection strings, so only db.conf changes.
- SSL/mTLS for ACK database connections. The ACK network is physically isolated and all hosts are legacy. Plain password auth over the local network is acceptable.

---

## Host Specification

| Field | Value |
|-------|-------|
| Hostname | `ack-db` |
| CTID | 246 (next in ACK range 240-254) |
| Type | LXC |
| IP | 10.1.0.246 |
| Bridge | vmbr2 |
| Privileged | no |
| Disk | 32 GB |
| RAM | 1024 MB |
| Cores | 1 |

Single-homed on the ACK network. MUD servers connect via 10.1.0.246:5432. No external interface needed.

---

## Database

### Schema

The ACK MUD server uses PostgreSQL with ~30 tables, tracked via a `schema_version` table (current version: 9). Key table groups:

**Game world (loaded at boot):** `areas`, `rooms`, `room_exits`, `room_extra_descs`, `mobiles`, `mob_scripts`, `mobile_specials`, `objects`, `object_extra_descs`, `object_affects`, `object_functions`, `shops`, `resets`

**Runtime state (async read/write):** `players`, `clans`, `rulers`, `brands`, `keep_chests`, `keep_chest_items`, `corpses`, `board_messages`, `boards`, `quest_templates`

**Help system (runtime read-only):** `help_entries`, `shelp_entries`, `lore_topics`, `lore_entries`

**Global:** `sysdata`, `bans`, `socials`, `schema_version`

Full-text search columns (tsvector with GIN indexes) exist on help/shelp/lore tables.

### Users

| User | Access | Purpose |
|------|--------|---------|
| `ack` | ALL on `acktng` database | MUD server runtime (read + write for player saves, OLC edits) |
| `ack_readonly` | SELECT on `acktng` database | tngdb API (read-only queries for helps, shelps, lores, skills) |

### Authentication

Password auth (`scram-sha-256`) via pg_hba. The ACK network is isolated, so plain password auth is acceptable (same trust model as the legacy setup).

```
# pg_hba.conf
hostssl acktng  ack           10.1.0.0/24    scram-sha-256
hostssl acktng  ack_readonly  10.1.0.0/24    scram-sha-256
hostssl acktng  ack_readonly  192.168.1.0/23 scram-sha-256
host    all     all           0.0.0.0/0      reject
```

The `ack_readonly` user is also allowed from the LAN (192.168.1.0/23) so the tngdb API can connect from outside the ACK network if needed.

---

## Bootstrap Script

New: `homelab/ack/bootstrap/03-setup-ack-db.sh`

1. Installs PostgreSQL 17 via pgdg
2. Self-signed SSL cert (CN=ack-db, SAN=IP:10.1.0.246)
3. Creates `acktng` database, `ack` and `ack_readonly` users
4. Configures pg_hba for ACK network access
5. Installs postgres_exporter on :9187
6. Firewall: allow PostgreSQL from 10.1.0.0/24, allow postgres_exporter from obs (10.1.0.100)
7. Configures DNS (ack-gateway at 10.1.0.240) and apt proxy

### Bootstrap order

Runs after ack-gateway (step 00) and before MUD servers (step 01). The ACK orchestrator (`pve-setup-ack.sh`) creates the host and runs the bootstrap as a new phase between gateway and MUD server setup.

---

## Migration

### Data migration from existing tngdb (192.168.1.112)

1. `pg_dump` the `acktng` database from the existing host
2. `pg_restore` into the new ack-db host
3. Verify schema_version matches (should be 9)
4. Verify row counts match for all tables

### MUD server cutover

Update `data/db.conf` on each MUD server from:
```
postgres://ack:password@192.168.1.112/acktng
```
to:
```
postgres://ack:password@10.1.0.246/acktng
```

Restart each MUD server. No schema changes, no code changes.

### tngdb API cutover (optional)

Update the tngdb `DATABASE_URL` environment variable to point to `10.1.0.246` (via the ACK network or LAN). The read-only user (`ack_readonly`) is allowed from both networks.

### Rollback

If migration fails, revert `data/db.conf` to point back to 192.168.1.112 and restart. No data loss possible since the old database is not modified during migration.

---

## Observability

- **postgres_exporter** on :9187, scraped by Prometheus on obs (10.1.0.100)
- **Promtail** ships PostgreSQL and system logs to Loki (tenant: ack) via `02-setup-promtail.sh`
- **Prometheus scrape target** added to the `ack` job in obs's prometheus.yml

---

## Changes

| Location | File | Change |
|----------|------|--------|
| `homelab/ack/bootstrap/` | `03-setup-ack-db.sh` | New: PostgreSQL host bootstrap |
| `homelab/ack/bootstrap/` | `pve-setup-ack.sh` | Add ack-db to HOSTS array, create between gateway and MUD servers |
| `homelab/ack/bootstrap/` | `01-setup-ack-mud.sh` | Update default db.conf path to point to 10.1.0.246 |
| `homelab/ack/` | `README.md` | Add ack-db to hosts table |
| `homelab/ack/` | `diagrams.md` | Add ack-db to topology and host reference |
| `homelab/bootstrap/` | `03-setup-obs.sh` | Add ack-db (10.1.0.246:9187) to Prometheus ack scrape targets |
| `architecture.md` | | Add ack-db to ACK guest summary |

---

## Trade-offs

**Password auth, not cert auth.** The ACK network is legacy infrastructure with no PKI. Adding cert auth would require enrolling ACK hosts in a CA, which is out of scope. The network is physically isolated (vmbr2), so password auth over the local network is the pragmatic choice.

**Shared database for all MUD servers.** All five MUD servers share one database host. This matches the current architecture (all servers connect to the same PostgreSQL instance). If isolation between MUD servers is needed later, separate databases can be created on the same host.

**32 GB disk.** The acktng database is small (game world data, player records). 32 GB is generous for the foreseeable future.

---

## Status

Pending approval.
