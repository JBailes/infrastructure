# Web Host Deployment

**Status:** Rejected (superseded by [web-site-split](../active/web-site-split.md))

## Problem

The web frontend (ackmud.com, aha.ackmud.com, bailes.us) has no host in the WOL infrastructure inventory. It needs a dual-homed LXC container serving HTTP/HTTPS on the external interface and talking to wol-accounts on the private network.

## Design

### Host

| Field | Value |
|-------|-------|
| Hostname | `web` |
| CTID | auto (dynamically allocated from 200+) |
| Type | LXC (unprivileged) |
| Private IP | 10.0.0.209 |
| External IP | 192.168.1.209 |
| Bridge (internal) | vmbr1 (untagged, shared) |
| Bridge (external) | vmbr0 |
| Disk | 16 GB |
| RAM | 1024 MB |
| Cores | 2 |
| VLAN | (empty, shared host) |

### Services

- **nginx**: reverse proxy, TLS termination (Let's Encrypt), serves Blazor WASM static files
- **ASP.NET Core API**: backend for aha.ackmud.com
- Sites: ackmud.com, aha.ackmud.com, bailes.us

### Network

- External interface (eth0): ports 80 and 443 open to the internet
- Internal interface (eth1): talks to wol-accounts (10.0.0.207:8443) via mTLS on the private network
- No SPIRE Agent needed (web is not a WOL service, uses step-ca certs for mTLS to accounts API)

### Bootstrap

New script: `bootstrap/24-setup-web.sh`

Installs:
- .NET 9 runtime (ASP.NET Core)
- nginx
- certbot (Let's Encrypt)
- ufw (80, 443 on external; SSH on internal)

### Inventory Changes

Add to `HOSTS` array in inventory.conf (shared section, CTID auto):
```
"web|auto|lxc|10.0.0.209|${PRIVATE_BRIDGE}|${PUBLIC_BRIDGE}|no|16|1024|2|192.168.1.209||Web frontend (ackmud.com, aha.ackmud.com, bailes.us)"
```

Add to `BOOTSTRAP_SHARED` sequence.
Add to `BOOT_ORDER` (order 8, alongside wol-a).
Add DNS entry to gateway dnsmasq config.

## Affected Files

- `infrastructure/proxmox/inventory.conf`: new host entry, bootstrap step, boot order
- `infrastructure/bootstrap/00-setup-gateway.sh`: DNS entry for web host
- `infrastructure/bootstrap/24-setup-web.sh`: new bootstrap script
- `infrastructure/hosts.md`: add to shared hosts table
- `infrastructure/proxmox/README.md`: update host count
- `infrastructure/bootstrap/21-setup-obs.sh`: add Prometheus target for web host

## Trade-offs

- Unprivileged LXC is sufficient since web does not run a SPIRE Agent
- Let's Encrypt requires outbound HTTPS to ACME servers (already allowed by gateway NAT)
- External-facing ports (80, 443) increase the attack surface; nginx handles TLS termination
