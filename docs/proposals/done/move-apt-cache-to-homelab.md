# Move apt-cache from WOL to Homelab Infrastructure

## Problem

The apt-cache host (apt-cacher-ng on 10.0.0.32 / 192.168.1.115) is defined and bootstrapped as part of the WOL infrastructure (`wol/proxmox/inventory.conf`, `wol/bootstrap/01-setup-apt-cache.sh`), but it is not a WOL service. It is a general-purpose package cache that serves WOL (10.0.0.0/20), homelab (192.168.0.0/23), and ACK (10.1.0.0/24) networks. The homelab already tri-homes it for ACK in `homelab/ack/bootstrap/pve-setup-ack.sh`.

Placing it in WOL means tearing down WOL also tears down the cache (unless `--include-cache` is avoided), and the WOL inventory carries a host that has nothing to do with the game.

## Approach

Move apt-cache ownership from `wol/` to `homelab/`. The WOL orchestrator continues to use it as a proxy (10.0.0.32:3142) but no longer creates, bootstraps, or manages it.

### Changes

#### 1. `homelab/bootstrap/pve-create-homelab.sh`

Add apt-cache to the `HOMELAB_HOSTS` array. It is dual-homed (vmbr0 + vmbr1), so it needs a second NIC added after creation, similar to how `pve-setup-ack.sh` adds a third NIC. Add a post-creation hook that attaches net1 (10.0.0.32/20 on vmbr1).

New host entry (created before vpn-gateway, since other homelab hosts also benefit from the cache):

```
apt-cache|auto|no|512|1|32|192.168.1.1|dual
```

The `dual` extra flag triggers adding net1 on vmbr1 with IP 10.0.0.32/20 (no gateway, private-side only).

#### 2. Move `wol/bootstrap/01-setup-apt-cache.sh` to `homelab/bootstrap/`

Rename to `00-setup-apt-cache.sh` (it runs first in the homelab sequence). Update any paths if needed.

#### 3. Add a bootstrap runner to `homelab/bootstrap/pve-create-homelab.sh`

The homelab orchestrator currently only creates containers. Add a `--deploy` mode (or a separate `pve-deploy-homelab.sh` script) that runs bootstrap scripts on created hosts, similar to the WOL deploy. The sequence:

```
00-setup-apt-cache.sh  -> apt-cache
01-setup-vpn-gateway.sh -> vpn-gateway
02-setup-bittorrent.sh  -> bittorrent
```

#### 4. `wol/proxmox/inventory.conf`

- Remove the `apt-cache` line from `HOSTS`
- Remove `apt-cache` from `SHARED_HOSTS`
- Remove `apt-cache` from `BOOT_ORDER`
- Remove the `"00|apt-cache|01-setup-apt-cache.sh|"` line from `BOOTSTRAP_SHARED`
- Remove the `"19|apt-cache|19-setup-promtail.sh|"` line from `BOOTSTRAP_SHARED`
- Update the comment "apt-cache must be first" to note that apt-cache is a homelab-managed host

#### 5. `wol/proxmox/lib/common.sh` (proxy-push logic)

No changes needed. The proxy-push logic already tests reachability (`echo > /dev/tcp/10.0.0.32/3142`) and gracefully skips if apt-cache is unreachable. It also already skips `apt-cache` by hostname. This continues to work: WOL just assumes apt-cache might exist and uses it if available.

#### 6. `wol/bootstrap/lib/common.sh` (shared functions)

The `configure_apt_proxy()` and `install_proxy_health_check()` functions reference 10.0.0.32. These are called by WOL bootstrap scripts to configure apt proxy on individual hosts. No changes needed: the IP stays the same, and these functions remain useful for WOL hosts.

#### 7. `wol/proxmox/pve-destroy-hosts.sh`

Remove the `--include-cache` flag and any apt-cache teardown logic. apt-cache teardown is now homelab's responsibility.

#### 8. Documentation updates

- `wol/hosts.md`: Remove apt-cache entry, add a note that it is managed by homelab
- `homelab/README.md`: Add apt-cache to the services table
- `proposals/active/apt-cache-host.md`: Update to reflect new ownership
- `wol/diagrams.md`: Update apt-cache annotation to note homelab ownership

## What does NOT change

- apt-cache IP (10.0.0.32), port (3142), or external IP (192.168.1.115)
- WOL proxy-push behavior (still probes and configures if reachable)
- WOL bootstrap scripts that call `configure_apt_proxy()` or `install_proxy_health_check()`
- ACK tri-homing in `homelab/ack/bootstrap/pve-setup-ack.sh`
- Promtail on apt-cache (move the promtail step to the homelab deploy sequence)

## Trade-offs

- **Pro**: apt-cache survives WOL teardown/rebuild without special flags
- **Pro**: WOL inventory only contains WOL hosts
- **Pro**: Homelab owns all shared infrastructure services
- **Con**: WOL deploy now has an external dependency (apt-cache must be up before WOL deploy for fast installs, but gracefully degrades if absent)
- **Con**: Homelab orchestrator needs a deploy/bootstrap capability (currently only creates containers)
