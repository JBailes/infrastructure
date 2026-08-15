# Dynamic CTID Allocation

> **Historical proposal.** This document records a design as it was proposed and
> implemented at the time. Host identities in the prose have been updated to the
> CTIDs and hostnames currently in use, so the containers named here can still be
> located. Code blocks are left verbatim and still contain the literal addresses
> and CTIDs used at the time -- do not copy them without checking. Some of what is
> described has since changed or been removed; see
> [architecture.md](../../../architecture.md) for what actually runs today.


## Status
Implemented.

## Problem
CTIDs were hardcoded across bootstrap scripts, inventory, hosts.md, and proposals. Adding a new host required manually finding the next available CTID. The homelab and WOL CTID ranges needed clear separation.

## Solution

### CTID ranges
| Range | Owner | IP pattern |
|-------|-------|------------|
| 100-199 | Homelab | 192.168.1.<CTID> |
| 200+ | WOL | Internal IPs (no CTID-to-IP mapping) |

### Implementation
- inventory.conf uses "auto" for all WOL CTIDs
- next_free_ctid() and resolve_ctid() helpers in both wol/proxmox/lib/common.sh and homelab/bootstrap/lib/common.sh
- pve-create-hosts.sh allocates CTIDs dynamically from 200+ at creation time
- pve-create-homelab.sh allocates CTIDs from 100+ (VPN gateway hardcoded at 104)
- After creation, all scripts resolve CTIDs by hostname via pct/qm list
- parse_host() auto-resolves "auto" CTIDs at runtime

### VPN gateway exception
The VPN gateway is hardcoded at CTID 104 / IP VM 111 `smoothrouter` because other homelab services (bittorrent) depend on its IP for their default gateway and DNS.
