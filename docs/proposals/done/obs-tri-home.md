# Proposal: Tri-home Observability Host in Homelab

> **Historical proposal.** This document records a design as it was proposed and
> implemented at the time. Host identities in the prose have been updated to the
> CTIDs and hostnames currently in use, so the containers named here can still be
> located. Code blocks are left verbatim and still contain the literal addresses
> and CTIDs used at the time -- do not copy them without checking. Some of what is
> described has since changed or been removed; see
> [architecture.md](../../../architecture.md) for what actually runs today.
>
> The WOL network described here has since been decommissioned.


**Status:** Active (implementing)
**Date:** 2026-03-27
**Affects:** obs host, `homelab/bootstrap/`, `wol/bootstrap/`, `wol/proxmox/inventory.conf`, documentation

---

## Problem

The observability host was previously owned by WOL infrastructure as `wol-obs` (dual-homed on vmbr0 + vmbr1). The ACK network (vmbr2) had no observability. The observability host is a shared infrastructure concern (like apt-cache), not a WOL-specific one.

---

## Approach

Renamed from `wol-obs` to `obs`. Moved from WOL inventory to `homelab/bootstrap/` as a tri-homed shared service. Added a third NIC on vmbr2 so ACK hosts can push logs and metrics directly.

### Network layout

| Interface | Bridge | IP | Network |
|-----------|--------|----|---------|
| eth0 | vmbr0 | CT 104 `obs` | Home LAN |
| eth1 | vmbr1 | 10.0.0.100/20 | WOL private |
| eth2 | vmbr2 | CT 104 `obs` | ACK private |

CTID: **100** (static, following the homelab convention of `X.X.X.{CTID}`).

### Changes made

- New: `homelab/bootstrap/03-setup-obs.sh` (tri-homed obs container)
- New: `homelab/ack/bootstrap/02-setup-promtail.sh` (Promtail for ACK hosts, TLS, tenant: ack)
- Deleted: `wol/bootstrap/17-setup-wol-obs.sh`
- Updated: `wol/proxmox/inventory.conf` (removed obs from HOSTS, SHARED_HOSTS, BOOT_ORDER, BOOTSTRAP_SHARED)
- Updated: all bootstrap scripts referencing obs by hostname or IP
- Updated: all documentation (architecture.md, hosts.md, diagrams, READMEs)
- Updated: firewall rules to allow 10.1.0.0/24 ingestion
- Updated: Loki multi-tenancy (added ACK tenant)
- Updated: Grafana datasource provisioning (added Loki ACK tenant)

### What did NOT change

- WOL Promtail still pushes to 10.0.0.100 over mTLS (tenant: wol)
- Proxmox observability still pushes to CT 104 `obs` (tenant: proxmox)
- Grafana serves on CT 104 `obs`
- Alert rules, retention policies, and cardinality guardrails unchanged

---

## Status

Implementing.
