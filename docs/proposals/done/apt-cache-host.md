# Apt Package Cache

## Problem

Every container and VM downloads the same Debian packages from the public internet during bootstrap. With 19 hosts, this means redundant downloads through the gateway NAT, slowing deploys and wasting bandwidth.

## Design

A dedicated `apt-cache` LXC container running apt-cacher-ng, tri-homed so it can fetch packages from the public internet and serve them to all private networks. Only apt traffic goes through the cache; all other HTTP/HTTPS traffic (curl, wget, etc.) goes directly through the gateway NAT.

### Host

| Field | Value |
|-------|-------|
| Hostname | `apt-cache` |
| CTID | 115 (static) |
| Type | LXC (unprivileged) |
| Private IP | 10.0.0.32 |
| External IP | 192.168.1.115 |
| Bridge (WOL) | vmbr1 (untagged, shared) |
| Bridge (ACK) | vmbr2 (10.1.0.32/24) |
| Bridge (LAN) | vmbr0 |
| Disk | 32 GB (cache storage) |
| RAM | 512 MB |
| Cores | 1 |
| VLAN | (empty, shared host) |

### How it works

- apt-cacher-ng listens on port 3142 on the private interface
- All containers and VMs set `Acquire::http::Proxy "http://10.0.0.32:3142"` (pushed by WOL orchestrator, configured individually by homelab scripts)
- First request for a package downloads it from the public mirror and caches it
- Subsequent requests are served from cache
- HTTPS apt repos are passed through (not cached, tunneled)
- Non-apt traffic (curl, wget) goes directly through gateway NAT

### Ownership

apt-cache is managed by the **homelab** infrastructure, not WOL. It is created and bootstrapped by `homelab/bootstrap/pve-create-homelab.sh`. The WOL orchestrator auto-configures apt proxy on WOL hosts if apt-cache is reachable at 10.0.0.32:3142, and gracefully falls back to direct downloads if it is not.

### What is preserved on teardown

WOL teardown (`pve-destroy-hosts.sh`) does not affect apt-cache since it is not a WOL host. Cached packages survive across WOL redeploys.

## Status

Implemented and active.
