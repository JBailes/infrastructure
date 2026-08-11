# Homelab Bootstrap Scripts

Each script is self-contained: run it on the Proxmox host and it creates the
LXC container (or VM), then pushes and executes itself inside to configure it.
Scripts are idempotent: they skip container creation if it already exists.

Hosts are referred to by **CTID and hostname**. Where a script must assign an
address at provisioning time it still carries a literal one; that is a property
of the script, not something documentation should restate.

## CTID drift

> **These scripts do not match the running host.** The CTIDs below are what each
> script provisions. Several containers were renumbered after they were first
> created, so re-running a script against the current host will not target the
> existing container -- it will try to create a new one at the old CTID.
>
> | Script provisions | Actually running as |
> |-------------------|---------------------|
> | CT 100 `obs` | CT 104 `obs` |
> | CT 115 `apt-cache` | CT 103 `apt-cache` |
> | CT 116 `bittorrent` | CT 108 `bittorrent` |
> | CT 117 `personal-web` | CT 106 `personal-web` |
> | CT 118 `nginx-proxy` | CT 105 `nginx-proxy` |
> | CT 121 `rakuen-web` | CT 107 `rakuen-web` |
> | CT 120 `wolf` | CT 113 `wolf` |
> | CT 122 `qwen103` | CT 140 `tierA-5080` |
> | VM 104 `vpn-gateway` | VM 111 `smoothrouter` |
> | CT 119 `media-stack` | not deployed |
>
> Use `resolve_ctid <hostname>` from `lib/common.sh` to find a host's real CTID
> rather than trusting the constants in these scripts.

## Usage

Run each script directly on the Proxmox host, in order:

```bash
# Phase 1: shared services (run in order)
./00-setup-apt-cache.sh           # apt-cache, package cache for all networks
./01-setup-vpn-gateway.sh         # vpn-gateway VM, OpenVPN gateway
./02-setup-bittorrent.sh          # bittorrent, qBittorrent-nox (needs the VPN gateway)
./03-setup-obs.sh                 # obs, observability stack (Loki, Prometheus, Grafana)

# Phase 2: web infrastructure
./06-setup-nginx-proxy.sh         # nginx-proxy, reverse proxy (multi-homed)
./07-setup-personal-web.sh        # personal-web, personal website (bailes.us)
./13-setup-rakuen-web.sh          # rakuen-web, Rakuen Software site (rakuensoftware.com)

# Phase 3: dashboards and host observability
./08-setup-dashboards.sh          # Grafana dashboards + blackbox_exporter on obs
./09-setup-proxmox-obs.sh         # pve-exporter + Promtail on the Proxmox host

# Phase 4: optional services
./10-setup-wolf.sh                # Wolf cloud gaming + Wolf Den (requires GPU)
./11-setup-ollama.sh              # llama.cpp LLM inference (requires AMD GPU)
./12-setup-media-stack.sh         # Media automation (Prowlarr, Sonarr, Radarr, Lidarr, Readarr)

# 03-setup-obs.sh automatically deploys Promtail to apt-cache, bittorrent,
# the VPN gateway, nginx-proxy, and personal-web after obs is configured.
#
# ACK Promtail is deployed by the ACK orchestrator (pve-setup-ack.sh) or
# manually per-host with ack/bootstrap/02-setup-promtail.sh.

# Or re-run configuration on an existing container:
./00-setup-apt-cache.sh --deploy-only
```

---

## 00 - Apt Cache (`apt-cache`)

Multi-homed LXC container running apt-cacher-ng. Caches .deb packages for
homelab and ACK hosts. First download fetches from public mirrors; subsequent
requests are served from cache.

- **eth0**: vmbr0 (home LAN, fetches packages)
- **eth1**: vmbr2 (ACK private network, serves cache)
- **Port**: 3142 (apt-cacher-ng)

Homelab and ACK scripts configure the apt proxy individually.

> The script still provisions the WOL interfaces on `vmbr1`/`vmbr3`. Those
> networks are decommissioned and the running container no longer has them.

---

## 01 - VPN Gateway (`vpn-gateway` VM; running as VM 111 `smoothrouter`)

Cloud-init VM that acts as a network gateway. Any device that sets its default
gateway and DNS to the VPN gateway has all traffic routed through a VPN tunnel.
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

On any LAN device, set both the default gateway and the DNS server to the VPN
gateway. To stop using the VPN, set both back to the home router.

---

## 02 - BitTorrent (`bittorrent`)

LXC container running qBittorrent-nox with three layers of VPN enforcement.
Downloads are stored on the NAS (192.168.1.254) over NFS.

### Prerequisites

- The VPN gateway VM must be running
- The NAS bittorrent export must be accessible

### VPN enforcement (three layers)

1. **VPN gateway kill switch**: the default gateway drops all forwarded traffic
   if its VPN tunnel is down
2. **Local iptables kill switch**: OUTPUT policy is DROP, blocking the home
   router directly so the container cannot send internet-bound traffic anywhere
   except through the VPN gateway, even if the default route is changed.
3. **Watchdog**: checks the default route and gateway reachability every 60
   seconds. Stops qBittorrent immediately if anything is wrong. Restarts it
   when conditions are restored.

> This script still hard-codes the old VPN gateway address in the watchdog it
> installs. The watchdog on the running container has since been changed to read
> its expected gateway from `/etc/vpn-watchdog.conf` and to fail loudly if that
> value is missing. Re-running this script would overwrite that fix.

### Storage

| Path | Purpose |
|------|---------|
| `/mnt/torrents/complete/` | Completed downloads |
| `/mnt/torrents/incomplete/` | In-progress downloads |

Both map to subdirectories of the NAS bittorrent export via NFS mount.

### Web UI

Port 80 (redirected to :8080) on the `bittorrent` container, from any device on the LAN.

---

## 03 - Observability (`obs`)

Multi-homed LXC container running the centralized observability stack.

- **eth0**: vmbr0 (Grafana :80, LAN/Proxmox log ingestion)
- **eth1**: vmbr2 (ACK Promtail TLS ingestion)

| Component | Port | Purpose |
|-----------|------|---------|
| Loki | 3100 | Log aggregation |
| Prometheus | 9090 | Metrics scraping |
| Alertmanager | 9093 | Alert routing (localhost only) |
| Grafana | 3000 | Dashboards (LAN interface only) |

### Loki tenants

| Tenant | Sources | Auth |
|--------|---------|------|
| `ack` | ACK MUD servers | TLS |
| `homelab` | apt-cache, VPN gateway, bittorrent, nginx-proxy, personal-web, rakuen-web | TLS |
| `proxmox` | Proxmox host | TLS + API key |

Must be deployed before ACK or LAN Promtail deployment.

> The `wol` tenant and its mTLS ingestion path are retained in the script but
> have no sources; WOL is decommissioned.

---

## 04 - Promtail ACK (deployed to ACK hosts)

Installs Promtail on ACK MUD servers. Pushes logs to Loki on `obs` (ACK
interface, :3100) with `tenant_id: ack` over TLS. Run on each ACK host after
obs is up.

Not run from the Proxmox host directly; deployed via `pct push`/`pct exec` or
by the ACK orchestrator (`pve-setup-ack.sh`).

---

## 05 - Promtail LAN (deployed to homelab LAN hosts)

Installs Promtail on LAN homelab hosts (apt-cache, VPN gateway, bittorrent).
Pushes logs to Loki on `obs` (LAN interface, :3100) with `tenant_id: homelab`
over TLS.

Run on each LAN host after obs is up. Deploy via `pct push`/`pct exec` for
LXC containers, or via `scp`/`ssh` for the VPN gateway VM.

---

## 06 - Nginx Proxy (`nginx-proxy`)

Multi-homed LXC container running nginx as a central reverse proxy for all web
sites. Handles TLS termination via certbot and routes by Host header:

- **ackmud.com** -> `ack-web` (:5000) via the ACK network
- **bailes.us** -> `personal-web` (:3000) via the LAN
- **rakuensoftware.com** -> `rakuen-web` (:3000) via the LAN
- **rakuensoft.com** -> 301 redirect to rakuensoftware.com

Also proxies legacy MUD WebSocket traffic (ports 18890, 8891, 8892) to `ack-web`
via TCP stream blocks.

- **eth0**: vmbr0 (LAN, incoming HTTPS from router)
- **eth1**: vmbr2 (ACK, reaches `ack-web`)

Backend servers run only their app server (node or service runtime) with no
nginx or TLS of their own. All certificate management is centralized here.

> The script still provisions a `vmbr1` interface for WOL reachability. That
> network is decommissioned.

---

## 07 - Personal Web (`personal-web`)

Single-homed LXC on the home LAN running a static file server (node serve) on
port 3000 for bailes.us.

- **eth0**: vmbr0
- TLS termination handled by `nginx-proxy`
- Firewall: :3000 from LAN (nginx-proxy connects here), SSH from LAN

---

## 13 - Rakuen Web (`rakuen-web`)

Single-homed LXC on the home LAN running a static file server (node serve) on
port 3000 for rakuensoftware.com.

- **eth0**: vmbr0
- TLS termination handled by `nginx-proxy`
- Firewall: :3000 from LAN (nginx-proxy connects here), SSH from LAN
- Sized 1024MB / 2 cores / 8GB: the site is a Vite + React SPA built
  in-container, which OOMs at personal-web's 256MB.
- Serves with `serve -s`, which rewrites unknown paths to index.html. The site
  is a single-page app, so without that flag /blog 404s on a hard refresh.

**Ordering:** the site repo `RakuenSoftware/rakuensoftware-web` must exist and be
public (or the container given credentials) before this script can clone it.

---

## 08 - Dashboards (deployed to `obs`)

Installs blackbox_exporter on obs and provisions Grafana dashboards:

1. **Service Health**: green/red stat tiles for all monitored services
2. **Host Utilization**: CPU and memory bar gauges and time series for all
   Proxmox containers, VMs, and the host node

Also writes blackbox HTTP/HTTPS scrape jobs to the Prometheus config for
services without native `/metrics` endpoints.

---

## 09 - Proxmox Host Observability (runs on the Proxmox host)

Installs observability agents directly on the Proxmox host (not in a container).
Unlike the other homelab scripts, this does NOT use `pct push`/`pct exec` since
it runs on the bare-metal host itself.

- **pve-exporter**: Python prometheus-pve-exporter in a venv at `/opt/pve-exporter`,
  listens on HTTP port 9221. Authenticates to the Proxmox API via a read-only
  API token (`prometheus@pve!metrics`). Exports CPU, memory, disk, and network
  metrics for all containers, VMs, and the host node.
- **Promtail**: ships Proxmox syslog, pveproxy access logs, and journal to Loki
  on `obs` (tenant: `proxmox`).
- **Firewall**: opens port 9221 to `obs` so Prometheus can scrape.

Prereq: obs (03-setup-obs.sh) must be running.

---

## 10 - Wolf Cloud Gaming (`wolf`, CTID configurable)

Privileged LXC container running Wolf (Games on Whales) for Moonlight-compatible
cloud gaming, plus Wolf Den for web-based management.

### Prerequisites

- GPU drivers must be installed on the Proxmox host
- For NVIDIA: driver version >= 530.30.02 and `nvidia-drm.modeset=1`

### Usage

```bash
./10-setup-wolf.sh                           # Defaults: 4 CPU, 4 GB RAM, 16 GB disk
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

1. Open Moonlight client, add the `wolf` host
2. Check Wolf logs for PIN: `pct exec <ctid> -- docker logs wolf-wolf-1`
3. Enter the PIN at the Wolf pairing endpoint on :47989

---

## 11 - LLM Inference (`qwen103`; running as CT 140 `tierA-5080`)

Privileged LXC container running llama.cpp (Vulkan) for local LLM inference
with AMD GPU acceleration (7900XTX via `/dev/dri` passthrough — Vulkan-only,
no ROCm/kfd).

> The script's filename is still `11-setup-ollama.sh` for git history. The
> running inference host is now CT 140 `tierA-5080`, which this script did not
> provision; treat the details below as describing the script, not the live
> host. The model is not auto-downloaded by default; either provide
> `--model <url>` or place the GGUF at `--model-path` before running.

### Prerequisites

- AMD GPU drivers (amdgpu) must be loaded on the Proxmox host
- Mesa Vulkan drivers (RADV) on the host
- GGUF model file available (download manually or pass `--model <url>`)

### Usage

```bash
./11-setup-ollama.sh                     # Defaults: hostname qwen103, Qwen3.6-27B at 128k
./11-setup-ollama.sh --deploy-only       # Re-deploy config to the existing container
./11-setup-ollama.sh --ctid 124 --hostname qwen124 --model-path /opt/models/other.gguf
```

### Reference model configuration

Qwen3.6-27B Q4_K_M (~17 GB on disk, ~16 GiB VRAM), served at 128k context
window. Native `ctx_train` is 262144, so 128k is within spec — no YaRN or
rope scaling required.

Server flags: `--gpu-layers -1 --ctx-size 131072 --flash-attn on
--cache-type-k q8_0 --cache-type-v q8_0 --device Vulkan0 --parallel 1
--batch-size 1024 --ubatch-size 512 --jinja --reasoning off`.

VRAM footprint (measured from startup log): 16,029 MiB model + 4,352 MiB
KV cache (q8_0 quantized) + 150 MiB recurrent state + 495 MiB compute =
~21 GiB on a 24 GiB 7900XTX.

Measured performance: ~38 tok/s decode, ~691 tok/s prompt processing at
8k tokens, ~377 tok/s at ~98k tokens. Needle-in-haystack recall at ~98k
tokens succeeds. See `homelab/llm-benchmarks.md` for full results.

### Systemd unit

`/etc/systemd/system/llama-qwen103.service` (not `llama-server.service`).
To swap models: edit the `-m /opt/models/<name>.gguf` path in `ExecStart`,
then `systemctl daemon-reload && systemctl restart llama-qwen103`.

### Services

| Service | Port | Purpose |
|---------|------|---------|
| llama-server | 8080 | OpenAI-compatible inference API |

### Firewall

Port 8080 is restricted to the home LAN (192.168.0.0/23) and localhost via
iptables rules inside the container.

### Quick start

```bash
# Test API (resolve the host's address with: pct list)
curl http://<llm-host>:8080/v1/models

# Chat (OpenAI-compatible)
curl http://<llm-host>:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "Qwen3.6-27B-Q4_K_M.gguf", "messages": [{"role": "user", "content": "hello"}]}'
```

### aimee delegate

Registered as an aimee agent named `qwen103`. Dispatch via:

```bash
aimee delegate code "..."       # or: review, explain, refactor, summarize, draft, reason, search, execute
aimee agent run code "..."      # same, lower-level form
aimee agent test qwen103        # connectivity check
```

---

## 12 - Media Stack (`media-stack`)

> Not currently deployed. No `media-stack` container exists on the host.

Privileged LXC container running the media automation stack via Docker Compose.
All services route through the VPN gateway.

- **eth0**: vmbr0 (LAN, gateway = VPN gateway)

### Prerequisites

- The VPN gateway VM must be running
- The `bittorrent` container must be running
- The NAS storage NFS export must be accessible

### Services

| Service | Port | Purpose |
|---------|------|---------|
| Prowlarr | 9696 | Centralized indexer manager |
| Sonarr | 8989 | TV series automation |
| Radarr | 7878 | Movie automation |
| Lidarr | 8686 | Music automation |
| Readarr | 8787 | Books/audiobooks automation |

All services connect to qBittorrent on the `bittorrent` container (:8080) with
per-app download categories (sonarr, radarr, lidarr, readarr).

### Storage

Single NFS mount at `/mnt/storage` (maps to the NAS storage export) enables
hardlinks between downloads and media libraries:

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
./12-setup-media-stack.sh                # Create CT and configure
./12-setup-media-stack.sh --deploy-only  # Re-run configuration on existing CT
```
