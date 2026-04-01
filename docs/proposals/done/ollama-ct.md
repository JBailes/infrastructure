# Ollama LXC Container

## Problem

There is no local LLM inference server in the homelab. Running Ollama on a
dedicated container with GPU acceleration (AMD 7900XTX) would provide fast local
inference for aimee delegates, development, and experimentation without
depending on external API providers.

## Approach

Create `homelab/bootstrap/11-setup-ollama.sh` following the existing bootstrap
pattern (same dual-mode structure as `10-setup-wolf.sh`).

### Container spec

| Property | Value |
|----------|-------|
| Hostname | ollama |
| CTID | 103 |
| IP | 192.168.1.103 |
| Network | vmbr0 (LAN only) |
| RAM | 64 GB (65536 MB) |
| Disk | 256 GB on `large` storage |
| CPU | 8 cores |
| GPU | AMD 7900XTX via /dev/dri + /dev/kfd passthrough |
| Privileged | Yes (required for GPU device passthrough) |

### Script structure

Follows the existing homelab bootstrap pattern:

- Without `--configure`: runs on Proxmox host, creates privileged LXC via
  `lib/common.sh`, configures AMD GPU passthrough (cgroup rules for 226:* and
  234:*, bind mounts for /dev/dri and /dev/kfd), starts the container, pushes
  the script inside and runs with `--configure`.

- With `--configure`: runs inside the container, installs Ollama via the
  official install script (https://ollama.com/install.sh), configures the
  systemd service to listen on 0.0.0.0:11434 and use the correct GPU, enables
  and starts the service.

### GPU passthrough (AMD 7900XTX)

LXC config additions:
```
lxc.cgroup2.devices.allow: c 226:* rwm
lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir
lxc.cgroup2.devices.allow: c 234:* rwm
lxc.mount.entry: /dev/kfd dev/kfd none bind,optional,create=file
```

### Services

| Service | Port | Purpose |
|---------|------|---------|
| Ollama | 11434 | OpenAI-compatible inference API |

### Firewall

Allow :11434 from LAN. SSH from LAN.

## Acceptance criteria

- [ ] Script creates LXC with specified resources on `large` storage
- [ ] AMD GPU (7900XTX) is passed through and accessible inside the container
- [ ] Ollama is installed, running, and listening on 0.0.0.0:11434
- [ ] `ollama list` works inside the container
- [ ] Script is idempotent (re-run skips existing container)

## Owner

aimee

## Test plan

1. Run `./11-setup-ollama.sh` on Proxmox host
2. Verify CT 103 exists with correct resources: `pct config 103`
3. Verify GPU access: `pct exec 103 -- ls /dev/dri /dev/kfd`
4. Verify Ollama is running: `curl http://192.168.1.103:11434/api/version`
5. Pull a test model: `pct exec 103 -- ollama pull qwen3:1.7b`
6. Run inference: `curl http://192.168.1.103:11434/v1/chat/completions -d '...'`

## Rollback plan

```bash
pct stop 103 && pct destroy 103
```

Remove `11-setup-ollama.sh` from the bootstrap directory and this entry from
the README.

## Operational impact

- Uses 64 GB of the host's RAM (significant allocation)
- 256 GB disk on large storage
- GPU is shared with other containers via bind-mounted device nodes; the
  host's amdgpu driver handles concurrent access (e.g. wolf and ollama can
  use the same GPU simultaneously)
