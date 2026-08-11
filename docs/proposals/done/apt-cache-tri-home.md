# Tri-home apt-cache on vmbr2

> **Historical proposal.** This document records a design as it was proposed and
> implemented at the time. Host identities in the prose have been updated to the
> CTIDs and hostnames currently in use, so the containers named here can still be
> located. Code blocks are left verbatim and still contain the literal addresses
> and CTIDs used at the time -- do not copy them without checking. Some of what is
> described has since changed or been removed; see
> [architecture.md](../../../architecture.md) for what actually runs today.
>
> The WOL network described here has since been decommissioned.


## Problem

The apt-cache container (CT 103 `apt-cache`) is currently created as dual-homed by `homelab/bootstrap/00-setup-apt-cache.sh` (vmbr0 + vmbr1), and then `homelab/ack/bootstrap/pve-setup-ack.sh` bolts on a third NIC (eth2 on vmbr2) after the fact. This splits ownership of apt-cache's network config across two scripts, using a stop/start cycle to hot-add the NIC. The IP used (10.1.0.50) is also inconsistent with the .32 convention used on the other bridges.

## Approach

Move all apt-cache networking into `00-setup-apt-cache.sh` so it is tri-homed from creation, and remove the apt-cache NIC logic from `pve-setup-ack.sh`.

### Network layout (after change)

| Interface | Bridge | IP | Network |
|-----------|--------|----|---------|
| eth0 | vmbr0 | CT 140 `tierA-5080` `apt-cache` | Home LAN |
| eth1 | vmbr1 | 10.0.0.32/20 | WOL private |
| eth2 | vmbr2 | 10.1.0.32/24 | ACK private |

### Changes

**`homelab/bootstrap/00-setup-apt-cache.sh`**

- Update header comments from "dual-homed" to "tri-homed", add eth2 line
- In `host_main()`: add `--net2 "name=eth2,bridge=vmbr2,ip=10.1.0.32/24"` alongside the existing net1 setup
- In `configure()`: add `ACK_NET="10.1.0.0/24"` variable
- In `configure_firewall()`: add iptables rules allowing apt-cacher-ng (port 3142) and health check (port 8080) from `ACK_NET`
- Update completion banner to mention all three networks

**`homelab/bootstrap/lib/common.sh`**

- Add `ACK_BRIDGE="vmbr2"` constant alongside existing `PRIVATE_BRIDGE="vmbr1"`

**`homelab/ack/bootstrap/pve-setup-ack.sh`**

- Remove `setup_apt_cache_nic()` function entirely
- Remove `setup_apt_cache_nic` call from `main()`
- Update completion banner: change `10.1.0.50` to `10.1.0.32`

**Documentation updates**

- `homelab/ack/diagrams.md`: update apt-cache IP from 10.1.0.50 to 10.1.0.32
- `homelab/diagrams.md`: add vmbr2/10.1.0.32 to apt-cache entry
- `proposals/active/apt-cache-host.md`: add vmbr2 row to host table, update description to tri-homed

### Trade-offs

- `00-setup-apt-cache.sh` now references vmbr2, which may not exist yet if ACK hasn't been set up. This is fine because `pct set --net2` just records the config; the interface will come up when vmbr2 is created. If vmbr2 never gets created, eth2 simply stays down with no impact.
- The ACK setup script (`pve-setup-ack.sh`) no longer needs to touch apt-cache at all, which simplifies it and removes the stop/start cycle.

## Status

Pending approval.
