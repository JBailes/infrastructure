# Overall Architecture README

## Problem

wol-docs has detailed READMEs and diagrams in each subdirectory (wol/, homelab/, homelab/ack/) but no single document that shows how the three networks relate to each other, what the Proxmox host looks like as a whole, and how shared services (apt-cache, gateways) bridge across networks.

## Design

A new `architecture.md` at the repository root. Linked from the top-level README.

### Sections

1. **Physical host** -- single Proxmox VE host, three bridges
2. **Network overview diagram** -- Mermaid diagram showing vmbr0/vmbr1/vmbr2, all subnets, and the shared services that bridge them
3. **Bridge reference table** -- vmbr0 (LAN), vmbr1 (WOL private, VLAN-aware), vmbr2 (ACK private)
4. **Per-network summaries** -- one paragraph each for WOL, Homelab, ACK, with guest counts and key services
5. **Shared services** -- apt-cache (tri-homed), how each network's gateway provides NAT/DNS
6. **Guest summary table** -- every CT/VM across all networks in one table
7. **Bootstrap order** -- which environments bootstrap first and cross-environment dependencies
8. **Cross-references** -- links to detailed READMEs, diagrams, and host inventories in each subdirectory

### What this is NOT

This document does not duplicate the detailed host inventories, port references, PKI chains, or bootstrap step tables that already exist in the subdirectory docs. It provides the 10,000-foot view and points readers to the right place for details.

### Affected files

- `architecture.md` (new)
- `README.md` (add link to architecture.md)

## Status

Active (implementing).
