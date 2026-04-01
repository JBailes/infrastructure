# Compact CTIDs and Multi-Environment Support

## Problem

The current inventory uses CTIDs 200-230 with gaps (200, 201, 202, 203, 204, 205, 207, 210, 212, 213, 215, 220, 230). This spread makes it difficult to deploy a second environment (e.g. a test realm alongside prod) within a compact CTID range.

We want to fit two full environments in CTIDs 200-220.

## Design

### Shared vs Per-Environment Hosts

Not all hosts need duplication. Infrastructure that is environment-agnostic stays shared; only game-specific services are duplicated.

**Shared (one copy):**

| Host | Purpose |
|------|---------|
| wol-gateway-a | NAT gateway / DNS / NTP |
| wol-gateway-b | NAT gateway / DNS / NTP |
| spire-server | SPIRE PKI server |
| step-ca | Intermediate CA |
| provisioning | vTPM provisioning CA |
| wol-accounts | Account auth API |
| db | PostgreSQL (accounts + SPIRE) |
| wol-obs | Observability stack |
| wol-a | Connection interface (routes players to chosen realm) |

**Per-environment (duplicated for test and prod):**

| Host | Purpose |
|------|---------|
| wol-realm | Game engine |
| wol-world | World data API |
| wol-world-db | PostgreSQL (world data) |
| wol-ai | AI service |

### CTID Layout

Shared hosts: 200-208 (9 slots)
Prod environment: 209-212 (4 slots)
Test environment: 213-216 (4 slots)
Reserved: 217-220 (future use)

Total: 17 hosts in CTIDs 200-216.

#### Shared Hosts (200-208)

| CTID | Host | Type | Private IP | External IP |
|------|------|------|-----------|-------------|
| 200 | wol-gateway-a | lxc | 10.0.0.8 | 192.168.1.200 |
| 201 | wol-gateway-b | lxc | 10.0.0.9 | 192.168.1.201 |
| 202 | spire-server | vm | 10.0.0.2 | - |
| 203 | step-ca | lxc | 10.0.0.3 | - |
| 204 | provisioning | lxc | 10.0.0.4 | - |
| 205 | wol-accounts | lxc | 10.0.0.5 | - |
| 206 | db | lxc | 10.0.0.10 | - |
| 207 | wol-obs | lxc | 10.0.0.15 | 192.168.1.215 |
| 208 | wol-a | lxc | 10.0.0.30 | 192.168.1.230 |

#### Prod Environment (209-212)

| CTID | Host | Type | Private IP |
|------|------|------|-----------|
| 209 | wol-realm-prod | lxc | 10.0.0.20 |
| 210 | wol-world-prod | lxc | 10.0.0.7 |
| 211 | wol-world-db-prod | lxc | 10.0.0.12 |
| 212 | wol-ai-prod | lxc | 10.0.0.13 |

#### Test Environment (213-216)

| CTID | Host | Type | Private IP |
|------|------|------|-----------|
| 213 | wol-realm-test | lxc | 10.0.0.21 |
| 214 | wol-world-test | lxc | 10.0.0.17 |
| 215 | wol-world-db-test | lxc | 10.0.0.18 |
| 216 | wol-ai-test | lxc | 10.0.0.19 |

### Player Routing

wol-a (the connection interface) remains shared. Players choose which realm (test or prod) at login. wol-a routes traffic to the appropriate wol-realm instance based on that selection. See separate proposal: `wol-realm-routing.md`.

### Inventory Changes

The `inventory.conf` format stays the same. Hosts are renumbered and per-environment hosts get `-prod` or `-test` suffixes.

## Affected Files

- `infrastructure/proxmox/inventory.conf` -- renumber CTIDs, rename per-env hosts, add test entries
- `infrastructure/proxmox/pve-create-hosts.sh` -- may need `--env` flag support
- `infrastructure/proxmox/pve-deploy.sh` -- bootstrap sequence updates for new hostnames
- `infrastructure/proxmox/pve-destroy-hosts.sh` -- support `--env` to tear down one environment
- `infrastructure/bootstrap/*.sh` -- update any hardcoded CTIDs or hostnames
- All SPIRE workload registration entries (step 12) need updating for new hostnames

## Trade-offs

- Renumbering CTIDs means a full teardown and rebuild (the destroy script handles this)
- Per-environment hostnames (e.g. `wol-realm-prod`) are longer but unambiguous
- IP addresses for test hosts are new allocations; no conflicts with existing assignments
- wol-a needs logic to route to the correct realm based on player choice (separate proposal)
