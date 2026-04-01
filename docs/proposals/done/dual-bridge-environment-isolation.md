# Dual-Bridge Environment Isolation

**Status:** Pending
**Date:** 2026-03-28

## Problem

The current WOL network uses a single VLAN-aware bridge (vmbr1, 10.0.0.0/20) with VLAN tags (10 for prod, 20 for test) and untagged for shared hosts. This requires the gateway to route between VLANs and the untagged network, which is fragile:

- Per-env hosts on VLAN 10/20 share a /20 subnet with shared hosts, so they try direct ARP delivery instead of routing through the gateway. This fails because VLANs provide L2 isolation.
- The gateway needs complex policy routing or /32 addressing hacks to work around same-subnet-different-VLAN issues.
- Gateway inter-VLAN routing adds unnecessary complexity and a single point of failure.
- apt-cache and other shared services are unreachable from VLAN-tagged hosts without gateway routing.

## Approach

Replace VLANs with two separate bridges. Shared hosts are dual-homed on both, giving direct L2 connectivity to both environments without any gateway routing.

### Network Layout

| Bridge | Subnet | Purpose | Proxmox host IP |
|--------|--------|---------|-----------------|
| vmbr0 | 192.168.1.0/23 | Home LAN (external) | 192.168.1.253 |
| vmbr1 | 10.0.0.0/24 | WOL prod + shared | 10.0.0.1 |
| vmbr2 | 10.1.0.0/23 | ACK private (unchanged) | 10.1.0.1 |
| vmbr3 | 10.0.1.0/24 | WOL test | 10.0.1.1 |

### Host Placement

**Shared hosts** (dual-homed on vmbr1 + vmbr3):
- wol-gateway-a: 10.0.0.200 (vmbr1) + 10.0.1.200 (vmbr3) + 192.168.1.200 (vmbr0)
- wol-gateway-b: 10.0.0.201 (vmbr1) + 10.0.1.201 (vmbr3) + 192.168.1.201 (vmbr0)
- spire-db: 10.0.0.202 (vmbr1) + 10.0.1.202 (vmbr3)
- ca: 10.0.0.203 (vmbr1) + 10.0.1.203 (vmbr3)
- spire-server: 10.0.0.204 (vmbr1) + 10.0.1.204 (vmbr3)
- provisioning: 10.0.0.205 (vmbr1) + 10.0.1.205 (vmbr3)
- wol-accounts-db: 10.0.0.206 (vmbr1) + 10.0.1.206 (vmbr3)
- wol-accounts: 10.0.0.207 (vmbr1) + 10.0.1.207 (vmbr3)
- wol-a: 10.0.0.208 (vmbr1) + 10.0.1.208 (vmbr3) + 192.168.1.208 (vmbr0)
- wol-web: 10.0.0.209 (vmbr1) + 10.0.1.209 (vmbr3)

Note: wol-a is the player-facing connection interface (telnet/WSS). It is tri-homed: vmbr0 for player connections, vmbr1 for prod backend services, vmbr3 for test backend services. The gateway is separate: it provides NAT for internal services reaching the internet.

**Prod hosts** (single-homed on vmbr1):
- wol-realm-prod: 10.0.0.210
- wol-world-prod: 10.0.0.211
- wol-ai-prod: 10.0.0.212
- wol-world-db-prod: 10.0.0.213
- wol-realm-db-prod: 10.0.0.214

**Test hosts** (single-homed on vmbr3):
- wol-realm-test: 10.0.1.215
- wol-world-test: 10.0.1.216
- wol-ai-test: 10.0.1.217
- wol-world-db-test: 10.0.1.218
- wol-realm-db-test: 10.0.1.219

### Key Design Decisions

1. **No VLAN tagging**: Remove `bridge-vlan-aware` from vmbr1 and all VLAN tags. VLANs served no purpose once we have separate bridges.

2. **Shared hosts see both networks**: By having a NIC on both vmbr1 and vmbr3, shared services (apt-cache, SPIRE, CA, databases) are directly reachable from both prod and test without any gateway routing.

3. **No cross-environment traffic**: Prod hosts (vmbr1 only) and test hosts (vmbr3 only) have no network path to each other. Isolation is enforced by bridge membership, not firewall rules.

4. **Gateway simplification**: Gateways provide NAT to the internet for both subnets but do NOT route between vmbr1 and vmbr3. Each gateway has three NICs: vmbr0 (external), vmbr1 (prod), vmbr3 (test). NAT masquerade for both 10.0.0.0/24 and 10.0.1.0/24.

5. **Subnet reduction**: /20 -> /24. 254 hosts per subnet is more than enough (current plan uses ~20 per env).

### Compatibility: obs and apt-cache

obs (10.0.0.100) and apt-cache (10.0.0.115) are homelab-managed on vmbr1. They will be directly reachable from prod hosts. For test hosts to reach them, obs and apt-cache would also need a NIC on vmbr3, or test hosts would go without apt-cache (using gateway NAT). I recommend adding vmbr3 NICs to obs and apt-cache for consistency.

## Affected Files

- `wol/proxmox/00-setup-proxmox-host.sh`: Create vmbr3, update vmbr1 (remove VLANs, /20 -> /24)
- `wol/proxmox/inventory.conf`: Update all IPs, remove VLAN fields, add test bridge/IPs, add dual-homing for shared hosts
- `wol/proxmox/pve-create-hosts.sh`: Support dual-homing shared hosts on vmbr1+vmbr3, remove VLAN trunk logic
- `wol/proxmox/lib/common.sh`: Remove VLAN references
- `wol/bootstrap/00-setup-gateway.sh`: Remove VLAN interface setup and inter-VLAN routing, add vmbr3 NAT
- `wol/bootstrap/lib/common.sh`: Update PRIVATE_NET, add TEST_NET
- All bootstrap scripts: Update hardcoded 10.0.0.X references for test hosts to 10.0.1.X
- `wol/proxmox/pve-destroy-hosts.sh`: No changes needed (destroys by CTID)

## Trade-offs

**Pros:**
- Simpler networking (no VLANs, no gateway inter-VLAN routing)
- Direct L2 connectivity between shared hosts and both environments
- Isolation by bridge membership (impossible to misconfigure firewall rules)
- apt-cache and other shared services directly reachable from both environments

**Cons:**
- Shared hosts need an extra NIC (trivial for LXC, slightly more for VMs)
- Two /24 subnets instead of one /20 (reduces available IPs per env, but 254 is plenty)
- obs and apt-cache (homelab-managed) need an extra NIC added manually or via homelab scripts
