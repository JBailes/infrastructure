# Dynamic CTID Allocation

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
The VPN gateway is hardcoded at CTID 104 / IP 192.168.1.104 because other homelab services (bittorrent) depend on its IP for their default gateway and DNS.
