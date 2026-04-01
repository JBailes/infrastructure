# Add tng-ai Monitoring and Make acktng URL Configurable

## Problem

1. tng-ai (the NPC dialogue AI service) has no Prometheus monitoring. If it goes
   down, there is no dashboard indication, and NPC dialogue silently fails.

2. The tng-ai URL in acktng is hardcoded as a `#define` in `config.h`
   (`http://192.168.1.111:8000/v1/chat`). This points at the LAN address, but
   acktng runs on the ACK isolated network (10.1.0.x). Changing the address
   requires recompilation.

## Approach

### 1. Make TNGAI_URL an environment variable (`acktng`)

- In `npc_dialogue.c`, read `TNGAI_URL` from the environment at init time via
  `getenv("TNGAI_URL")`, falling back to the `#define` default.
- Update the `#define` default in `config.h` to point at the ACK-network address
  (`http://10.1.0.248:8000/v1/chat`).

This lets the URL be changed at runtime without recompilation, and the default
now uses the direct ACK-network path instead of routing through the gateway.

### 2. Add tng-ai to monitoring (`wol-docs`)

tng-ai exposes `GET /health` but no `/metrics` endpoint, so we use a blackbox
HTTP probe (same pattern as personal-web, nginx-proxy, and qbittorrent).

- Add `http://10.1.0.248:8000/health` to the blackbox scrape targets in
  `08-setup-dashboards.sh`.
- Add a `probe_success` query for tng-ai to the ACK Services panel on the
  Service Health dashboard, since tng-ai serves the ACK MUD.

### 3. Migration strategy (future work)

tng-ai currently runs on CT 111 (192.168.1.111) on the home LAN. The target
state is a dedicated container on the ACK subnet:

- **CT 248** (`tng-ai`, 10.1.0.248) on vmbr2 (ACK network). CT 246 is reserved
  for ack-db (see `proposals/pending/ack-database-host.md`).
- New bootstrap script (`homelab/ack/bootstrap/05-setup-tng-ai.sh`) to create
  the container, install Python/dependencies, deploy the tng-ai service, and
  configure systemd
- Once CT 248 is live, update acktng's default URL to point to 10.1.0.248
- During migration: set `TNGAI_URL=http://192.168.1.111:8000/v1/chat` in the
  acktng systemd unit to keep using the old host until CT 248 is ready
- After cutover: remove the env var override and decommission CT 111's tng-ai
  service

## Affected files

**acktng (ackmudhistoricalarchive/acktng#998):**
- `src/headers/config.h` (update default URL)
- `src/npc_dialogue.c` (read env var with fallback)

**wol-docs (JBailes/wol-docs#235):**
- `homelab/bootstrap/08-setup-dashboards.sh` (blackbox target + dashboard panel)

## Trade-offs

- The blackbox probe only checks HTTP 200 reachability of `/health`. It does not
  verify that Groq API credentials are valid or that the LLM is responding. A
  health check that pings Groq would add latency and external dependency to the
  probe.
- The env var approach uses `getenv()` at init time only, not per-request. If
  the URL needs to change, the MUD must be restarted.
- The monitoring probe targets 10.1.0.246, which won't resolve until the
  migration creates CT 248. The tile will show red until then, which is accurate
  (the service isn't on the ACK subnet yet).
