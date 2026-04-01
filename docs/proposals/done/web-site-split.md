# Proposal: Split Web Project into Three Repos and Hosts

**Status:** Pending
**Date:** 2026-03-27
**Affects:** `web/` repo, WOL bootstrap, ACK bootstrap, homelab bootstrap, nginx configs, DNS

---

## Problem

The `web` repo is a monolith serving three unrelated sites from a single host (CT 209):

- **ackmud.com** (WOL game client, Blazor WASM)
- **aha.ackmud.com** (ACK Historical Archive, Blazor WASM)
- **bailes.us** (personal site, React SPA)

These sites belong to different infrastructure domains. The AHA site is ACK-specific (proxies to ACK game servers, reads acktng help/lore files), ackmud.com is the WOL game client, and bailes.us is a personal project with no relation to either. Bundling them forces a single deployment pipeline, shared failure domain, and misplaced ownership (all three currently live in WOL infrastructure).

---

## Goals

1. Each site in its own repo with independent deployment
2. Each site on the appropriate network/host
3. No shared runtime dependencies between sites
4. Clean separation of ACK, WOL, and personal infrastructure concerns

---

## Non-goals

- Rewriting the Blazor WASM clients or the React SPA. The frontend code moves as-is.
- Changing domain names or URLs.
- SSL/TLS changes (each host handles its own certbot enrollment).

---

## Proposed Split

### 1. aha.ackmud.com -> ACK space

**Repo:** `ack-web` (new)

**Contents:**
- `AckWeb.Client.Aha/` (Blazor WASM client)
- `AckWeb.Api/` (ASP.NET Core backend, AHA-specific endpoints only)
- nginx config for aha.ackmud.com
- systemd unit

**API endpoints (AHA-specific):**
- `GET /api/who` - proxies to acktng game server for live player list
- `GET /api/gsgp` - proxies to acktng game server for game stats
- `GET /api/reference/{type}/{topic}` - reads help/shelp/lore from acktng data files

**Host:** `ack-web` on the ACK network

| Field | Value |
|-------|-------|
| Hostname | `ack-web` |
| CTID | 247 (next in ACK range 240-254) |
| Type | LXC |
| ACK IP | 10.1.0.247 |
| External IP | 192.168.1.247 |
| Bridges | vmbr2 (ACK) + vmbr0 (LAN, for HTTPS/certbot) |
| Disk | 8 GB |
| RAM | 512 MB |
| Cores | 1 |

Dual-homed: external interface serves HTTPS (aha.ackmud.com), internal interface connects to ACK game servers. WebSocket proxy ports (18890, 8891, 8892) for legacy MUD clients move to this host.

**Bootstrap:** `homelab/ack/bootstrap/04-setup-ack-web.sh`

**Observability:** Promtail (tenant: ack), service health check from the .NET API `/health` endpoint.

### 2. ackmud.com -> WOL space

**Repo:** `wol-client-web` (new, separate from the existing `wol-client` Flutter app)

**Contents:**
- `AckWeb.Client.Wol/` (Blazor WASM client)
- WOL-specific API backend (if needed, or static-only if the Blazor client talks directly to WOL APIs via WebSocket)
- nginx config for ackmud.com
- systemd unit

**Host:** rename existing `web` (CT 209) to `wol-web` in WOL infrastructure, serves only ackmud.com.

If the WOL Blazor client is purely static (WASM connecting to wol-a via WebSocket on port 6969), it could be served by nginx with no .NET backend, reducing the host to a static file server.

**Bootstrap:** `wol/bootstrap/18-setup-wol-web.sh` (renamed from `18-setup-web.sh`, simplified for ackmud.com only)

**Observability:** Promtail (tenant: wol), nginx health check.

### 3. bailes.us -> homelab space

**Repo:** `bailes-us` (new)

**Contents:**
- `personal/` (React + Vite + TypeScript SPA)
- nginx config for bailes.us
- No backend, purely static

**Host:** `personal-web` in homelab

| Field | Value |
|-------|-------|
| Hostname | personal-web |
| CTID | 117 (next available in homelab range) |
| Type | LXC |
| LAN IP | 192.168.1.117 |
| Bridge | vmbr0 (LAN only) |
| Disk | 4 GB |
| RAM | 256 MB |
| Cores | 1 |

Single-homed on the LAN. Serves a static React SPA via nginx. No API, no .NET runtime needed.

**Bootstrap:** `homelab/bootstrap/06-setup-personal-web.sh`

**Observability:** Promtail (tenant: homelab), nginx health check.

---

## Migration Plan

### Phase 1: Create new repos

1. Create `ack-web` repo with AHA client, AHA-specific API endpoints, and nginx config
2. Create `bailes-us` repo with the personal React SPA and nginx config
3. Create `wol-client-web` repo (or repurpose `web` repo) with WOL Blazor client

### Phase 2: Create new hosts

1. Bootstrap `ack-web` (CT 247) on the ACK network
2. Bootstrap `personal-web` (CT 117) on the LAN
3. Update `web` (CT 209) to serve only ackmud.com

### Phase 3: DNS cutover

1. Point `aha.ackmud.com` A record to 192.168.1.247 (ack-web)
2. Point `bailes.us` A record to 192.168.1.117 (personal-web)
3. `ackmud.com` stays on 192.168.1.209 (wol-web)

### Phase 4: Decommission

1. Remove AHA and personal site code from the `web` repo
2. Rename `web` host to `wol-web` (inventory, DNS, bootstrap script, docs)
3. Remove unused ports (18890, 8891, 8892) from the wol-web host firewall
4. Rename and simplify `18-setup-web.sh` to `18-setup-wol-web.sh`

---

## Changes

| Location | File | Change |
|----------|------|--------|
| `homelab/ack/bootstrap/` | `04-setup-ack-web.sh` | New: AHA web host bootstrap |
| `homelab/ack/bootstrap/` | `pve-setup-ack.sh` | Add ack-web to HOSTS array |
| `homelab/ack/` | `README.md` | Add ack-web to hosts table |
| `homelab/bootstrap/` | `06-setup-personal-web.sh` | New: personal web host bootstrap |
| `homelab/bootstrap/` | `README.md` | Add personal-web |
| `homelab/` | `README.md` | Add personal-web to services table |
| `wol/bootstrap/` | `18-setup-web.sh` -> `18-setup-wol-web.sh` | Rename, simplify to serve only ackmud.com |
| `wol/proxmox/` | `inventory.conf` | Rename `web` to `wol-web`, update description |
| `wol/bootstrap/` | `00-setup-gateway.sh` | Rename DNS entry from `web` to `wol-web` |
| `architecture.md` | | Update guest summaries, add new hosts |
| Various diagrams | | Add ack-web and personal-web |

---

## Trade-offs

**Three hosts instead of one.** Each site gets its own failure domain and deployment pipeline, but uses more resources. The personal site needs only 256 MB RAM and 4 GB disk, and ack-web is similarly lightweight. Total additional resource cost is modest.

**Duplicated nginx/certbot setup.** Each host runs its own nginx and certbot. This is intentional: independent TLS enrollment means one cert failure doesn't take down all three sites.

**AHA backend needs acktng data files.** The AHA API reads help/shelp/lore files from the acktng source tree. On the new ack-web host, these files need to be present. Options: clone the acktng repo at bootstrap, or mount the data from the acktng MUD server via NFS/bind mount. The simplest approach is cloning the repo (same pattern as the current web setup).

**WebSocket proxy ports.** The legacy MUD WebSocket proxies (18890, 8891, 8892) currently live on the web host. They move to ack-web since they connect to ACK game servers. Players who use the web-based MUD client will connect to 192.168.1.247 instead of 192.168.1.209 for these ports.

---

## Status

Pending approval.
