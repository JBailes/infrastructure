# Homelab Bootstrap Scripts

Each script is self-contained: run it on the Proxmox host and it creates the
LXC container (or VM), then pushes and executes itself inside to configure it.
Scripts are idempotent: they skip container creation if it already exists.

## Usage

Run each script directly on the Proxmox host, in order:

```bash
# Phase 1: shared services (run in order)
./00-setup-apt-cache.sh           # CT 115, package cache for all networks
./01-setup-vpn-gateway.sh         # VM 104, OpenVPN gateway
./02-setup-bittorrent.sh          # CT 116, qBittorrent-nox (needs vpn-gateway)
./03-setup-obs.sh                 # CT 100, observability stack (Loki, Prometheus, Grafana)

# Phase 2: web infrastructure
./06-setup-nginx-proxy.sh         # CT 118, nginx reverse proxy (tri-homed)
./07-setup-personal-web.sh        # CT 117, personal website (bailes.us)

# Phase 3: dashboards and host observability
./08-setup-dashboards.sh          # Grafana dashboards + blackbox_exporter on obs
./09-setup-proxmox-obs.sh        # pve-exporter + Promtail on the Proxmox host

# Phase 4: optional services
./10-setup-wolf.sh                # Wolf cloud gaming + Wolf Den (requires GPU)
./11-setup-ollama.sh              # llama.cpp LLM inference (requires AMD GPU)
./12-setup-media-stack.sh         # Media automation (Prowlarr, Sonarr, Radarr, Lidarr, Readarr)

# 03-setup-obs.sh automatically deploys Promtail to apt-cache, bittorrent,
# vpn-gateway, nginx-proxy, and personal-web after obs is configured.
#
# ACK Promtail is deployed by the ACK orchestrator (pve-setup-ack.sh) or
# manually per-host with ack/bootstrap/02-setup-promtail.sh.

# Or re-run configuration on an existing container:
./00-setup-apt-cache.sh --deploy-only
```

All CTIDs are static. IPs follow the convention `X.X.X.{CTID}` on each network.

| Hostname | CTID | IP |
|----------|------|----|
| obs | 100 | 192.168.1.100 (LAN), 10.0.0.100 (WOL), 10.1.0.100 (ACK) |
| vpn-gateway | 104 | 192.168.1.104 |
| apt-cache | 115 | 192.168.1.115 (LAN), 10.0.0.115 (WOL), 10.1.0.115 (ACK) |
| bittorrent | 116 | 192.168.1.116 |
| personal-web | 117 | 192.168.1.117 |
| nginx-proxy | 118 | 192.168.1.118 (LAN), 10.0.0.118 (WOL), 10.1.0.118 (ACK) |
| media-stack | 119 | 192.168.1.119 |
| llm | 103 | 192.168.1.103 |

---

## 00 - Apt Cache (CTID 115, 192.168.1.115 / 10.0.0.115 / 10.1.0.115)

Tri-homed LXC container running apt-cacher-ng. Caches .deb packages for all
homelab, WOL, and ACK hosts. First download fetches from public mirrors; subsequent
requests are served from cache.

- **eth0**: 192.168.1.115 on vmbr0 (home LAN, fetches packages)
- **eth1**: 10.0.0.115/20 on vmbr1 (WOL private network, serves cache)
- **eth2**: 10.1.0.115/24 on vmbr2 (ACK private network, serves cache)
- **Port**: 3142 (apt-cacher-ng)

The WOL orchestrator auto-configures apt proxy on WOL hosts if apt-cache is reachable.
Homelab and ACK scripts configure it individually.

---

## 01 - VPN Gateway (VMID 104, 192.168.1.104)

Cloud-init VM that acts as a network gateway. Any device that sets its default
gateway and DNS to 192.168.1.104 has all traffic routed through a VPN tunnel.
If the tunnel drops, a kill switch blocks all forwarded traffic until it
reconnects. Traffic is never sent unencrypted.

### Prerequisites

Before running the script, place your VPN provider's files in `secrets/`:

```
homelab/bootstrap/
├── 01-setup-vpn-gateway.sh
├── secrets/
│   ├── client.ovpn          <-- your OpenVPN config (certs, keys, endpoints)
│   └── auth.txt             <-- line 1: username, line 2: password
└── README.md
```

The `secrets/` directory is gitignored. Never commit these files.

For NordVPN, the service credentials (not your account login) are available in
the NordVPN dashboard under manual setup.

### Using the gateway

On any LAN device, change:

- **Default gateway**: `192.168.1.1` -> `192.168.1.104`
- **DNS server**: -> `192.168.1.104`

To stop using VPN, change both back to `192.168.1.1`.

---

## 02 - BitTorrent (CTID 116, 192.168.1.116)

LXC container running qBittorrent-nox with three layers of VPN enforcement.
Downloads are stored on the NAS at `//192.168.1.254/storage/bittorrent`.

### Prerequisites

- VPN gateway (VMID 104, 192.168.1.104) must be running
- NAS share `//192.168.1.254/storage/bittorrent` must be accessible via guest access

### VPN enforcement (three layers)

1. **VPN gateway kill switch**: the default gateway (192.168.1.104) drops all
   forwarded traffic if its VPN tunnel is down
2. **Local iptables kill switch**: OUTPUT policy is DROP, only allows traffic
   to the VPN gateway and the NAS (port 445). The container cannot send
   internet-bound traffic anywhere except through the VPN gateway, even if
   the default route is changed.
3. **Watchdog**: checks the default route and gateway reachability every 60
   seconds. Stops qBittorrent immediately if anything is wrong. Restarts it
   when conditions are restored.

### Storage

| Path | Purpose |
|------|---------|
| `/mnt/torrents/complete/` | Completed downloads |
| `/mnt/torrents/incomplete/` | In-progress downloads |

Both map to subdirectories of `192.168.1.254:/mnt/data/storage/bittorrent` via NFS
mount.

### Web UI

`http://192.168.1.116` from any device on the LAN.

---

## 03 - Observability (CTID 100, 192.168.1.100 / 10.0.0.100 / 10.1.0.100)

Tri-homed LXC container running the centralized observability stack. Collects
logs and metrics from all three networks.

- **eth0**: 192.168.1.100 on vmbr0 (Grafana :80, LAN/Proxmox log ingestion)
- **eth1**: 10.0.0.100/20 on vmbr1 (WOL Promtail mTLS ingestion, Prometheus scrape)
- **eth2**: 10.1.0.100/24 on vmbr2 (ACK Promtail TLS ingestion)

| Component | Port | Purpose |
|-----------|------|---------|
| Loki | 3100 | Log aggregation (all three interfaces) |
| Prometheus | 9090 | Metrics scraping |
| Alertmanager | 9093 | Alert routing (localhost only) |
| Grafana | 3000 | Dashboards (LAN interface only) |

### Loki tenants

| Tenant | Sources | Auth |
|--------|---------|------|
| `wol` | WOL service hosts | mTLS (cfssl CA client certs) |
| `ack` | ACK MUD servers | TLS |
| `homelab` | apt-cache, vpn-gateway, bittorrent, nginx-proxy, personal-web | TLS |
| `proxmox` | Proxmox host | TLS + API key |

Must be deployed before WOL Promtail steps (step 18 in the WOL bootstrap) and
before ACK or LAN Promtail deployment.

---

## 04 - Promtail ACK (deployed to ACK hosts)

Installs Promtail on ACK MUD servers. Pushes logs to Loki at 10.1.0.100:3100
with `tenant_id: ack` over TLS. Run on each ACK host after obs is up.

Not run from the Proxmox host directly; deployed via `pct push`/`pct exec` or
by the ACK orchestrator (`pve-setup-ack.sh`).

---

## 05 - Promtail LAN (deployed to homelab LAN hosts)

Installs Promtail on LAN homelab hosts (apt-cache, vpn-gateway, bittorrent).
Pushes logs to Loki at 192.168.1.100:3100 with `tenant_id: homelab` over TLS.

Run on each LAN host after obs is up. Deploy via `pct push`/`pct exec` for
LXC containers, or via `scp`/`ssh` for the vpn-gateway VM.

---

## 06 - Nginx Proxy (CTID 118, 192.168.1.118 / 10.0.0.118 / 10.1.0.118)

Tri-homed LXC container running nginx as a central reverse proxy for all web
sites. Handles TLS termination via certbot and routes by Host header:

- **ackmud.com** -> wol-web (10.0.0.209:5000) via WOL network
- **aha.ackmud.com** -> ack-web (10.1.0.247:5000) via ACK network
- **bailes.us** -> personal-web (192.168.1.117:3000) via LAN

Also proxies legacy MUD WebSocket traffic (ports 18890, 8891, 8892) to ack-web
via TCP stream blocks.

- **eth0**: 192.168.1.118/23 on vmbr0 (LAN, incoming HTTPS from router)
- **eth1**: 10.0.0.118/20 on vmbr1 (WOL, reach wol-web)
- **eth2**: 10.1.0.118/24 on vmbr2 (ACK, reach ack-web)

Backend servers run only their app server (Kestrel/.NET or node serve) with no
nginx or TLS of their own. All certificate management is centralized here.

---

## 07 - Personal Web (CTID 117, 192.168.1.117)

Single-homed LXC on the home LAN running a static file server (node serve) on
port 3000 for bailes.us.

- **eth0**: 192.168.1.117/23 on vmbr0
- TLS termination handled by nginx-proxy (192.168.1.118)
- Firewall: :3000 from LAN (nginx-proxy connects here), SSH from LAN

---

## 08 - Dashboards (deployed to obs, CTID 100)

Installs blackbox_exporter on obs and provisions Grafana dashboards:

1. **Service Health**: green/red stat tiles for all monitored services
2. **Host Utilization**: CPU and memory bar gauges and time series for all
   Proxmox containers, VMs, and the host node

Also writes blackbox HTTP/HTTPS scrape jobs to the Prometheus config for
services without native `/metrics` endpoints.

---

## 09 - Proxmox Host Observability (runs on the Proxmox host, 192.168.1.253)

Installs observability agents directly on the Proxmox host (not in a container).
Unlike the other homelab scripts, this does NOT use `pct push`/`pct exec` since
it runs on the bare-metal host itself.

- **pve-exporter**: Python prometheus-pve-exporter in a venv at `/opt/pve-exporter`,
  listens on HTTP port 9221. Authenticates to the Proxmox API via a read-only
  API token (`prometheus@pve!metrics`). Exports CPU, memory, disk, and network
  metrics for all containers, VMs, and the host node.
- **Promtail**: ships Proxmox syslog, pveproxy access logs, and journal to Loki
  at 192.168.1.100:3100 (tenant: `proxmox`).
- **Firewall**: opens port 9221 from obs (192.168.1.100) so Prometheus can scrape.

Prereq: obs (03-setup-obs.sh) must be running.

---

## 10 - Wolf Cloud Gaming (CTID configurable, default 120)

Privileged LXC container running Wolf (Games on Whales) for Moonlight-compatible
cloud gaming, plus Wolf Den for web-based management.

### Prerequisites

- GPU drivers must be installed on the Proxmox host
- For NVIDIA: driver version >= 530.30.02 and `nvidia-drm.modeset=1`

### Usage

```bash
./10-setup-wolf.sh                           # Defaults: CTID 120, 4 CPU, 4 GB RAM, 16 GB disk
./10-setup-wolf.sh --ctid 125 --cpu 8        # Custom CTID and CPU
./10-setup-wolf.sh --storage fast --disk 32  # Custom storage and disk
```

### GPU support

The script detects GPUs on the host and prompts for selection if multiple are
found. Each option shows the render device, kernel driver, and vendor:

```
Available GPUs:
  1) /dev/dri/renderD128 (i915, Intel)
  2) /dev/dri/renderD129 (amdgpu, AMD)

Select GPU for Wolf [1]:
```

| Vendor | Driver | Passthrough | Encoding |
|--------|--------|-------------|----------|
| Intel  | i915/xe | /dev/dri | QuickSync (VAAPI) |
| AMD    | amdgpu | /dev/dri + /dev/kfd | VAAPI |
| NVIDIA | nvidia | /dev/nvidia* + /dev/dri | CUDA (manual driver volume) |

### Services

| Service | Port | Purpose |
|---------|------|---------|
| Wolf | 47984-48200 | Moonlight streaming (host network mode) |
| Wolf Den | 8080 | Web management UI |

### Moonlight pairing

1. Open Moonlight client, add server IP
2. Check Wolf logs for PIN: `pct exec <ctid> -- docker logs wolf-wolf-1`
3. Enter PIN at `http://<IP>:47989/pin/#<PIN>`

---

## 11 - LLM Inference (CTID 103, 192.168.1.103)

Privileged LXC container running llama.cpp (Vulkan) for local LLM inference
with AMD GPU acceleration (7900XTX via /dev/dri + /dev/kfd passthrough).

### Prerequisites

- AMD GPU drivers (amdgpu) must be loaded on the Proxmox host
- `/dev/kfd` must exist on the host

### Usage

```bash
./11-setup-ollama.sh                            # Defaults: CTID 103, 8 CPU, 64 GB RAM, 256 GB disk on large
                                                #   downloads Qwen3.5-27B Opus v2 Q4_K_M
./11-setup-ollama.sh --model <url>              # Use a different HuggingFace GGUF URL
./11-setup-ollama.sh --no-model                 # Skip model download
./11-setup-ollama.sh --deploy-only              # Re-deploy config to existing CT
```

### Default model

Qwen3.5-27B Claude Opus v2 distilled (Jackrong), Q4_K_M quantization. 16 GB
on disk, fits entirely in the 7900XTX's 24 GB VRAM with 32k context window
(~41 tok/s generation, ~721 tok/s prompt processing).

See `homelab/llm-benchmarks.md` for full benchmark results across all tested models.

### Services

| Service | Port | Purpose |
|---------|------|---------|
| llama-server | 8080 | OpenAI-compatible inference API |

### Firewall

Port 8080 is restricted to `192.168.0.0/23` (home LAN) and localhost via
iptables rules inside the container.

### Quick start

```bash
# Test API
curl http://192.168.1.103:8080/v1/models

# Chat (OpenAI-compatible)
curl http://192.168.1.103:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "qwen3.5-27b-opus-v2", "messages": [{"role": "user", "content": "hello"}]}'
```

---

## 12 - Media Stack (CTID 119, 192.168.1.119)

Privileged LXC container running the media automation stack via Docker Compose.
All services route through the VPN gateway (192.168.1.104).

- **eth0**: 192.168.1.119/23 on vmbr0 (LAN, gateway = VPN gateway)

### Prerequisites

- VPN gateway (VMID 104, 192.168.1.104) must be running
- BitTorrent LXC (CT 116, 192.168.1.116) must be running
- NAS NFS export `192.168.1.254:/mnt/data/storage` must be accessible

### Services

| Service | Port | Purpose |
|---------|------|---------|
| Prowlarr | 9696 | Centralized indexer manager |
| Sonarr | 8989 | TV series automation |
| Radarr | 7878 | Movie automation |
| Lidarr | 8686 | Music automation |
| Readarr | 8787 | Books/audiobooks automation |

All services connect to qBittorrent at 192.168.1.116:8080 with per-app
download categories (sonarr, radarr, lidarr, readarr).

### Storage

Single NFS mount at `/mnt/storage` (maps to `192.168.1.254:/mnt/data/storage`)
enables hardlinks between downloads and media libraries:

| Path | Purpose |
|------|---------|
| `/mnt/storage/bittorrent/complete/{category}` | Completed downloads per app |
| `/mnt/storage/video/TV Shows/` | TV library |
| `/mnt/storage/video/Movies/` | Movie library |
| `/mnt/storage/music/` | Music library |
| `/mnt/storage/books/` | Books library |

### Backups

Config databases are backed up daily at 03:00 to
`/mnt/storage/backup/media-stack/` with 14-day retention.

### Usage

```bash
./12-setup-media-stack.sh               # Create CT and configure
./12-setup-media-stack.sh --deploy-only  # Re-run configuration on existing CT
```
