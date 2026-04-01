# BitTorrent LXC

## Problem

Need a dedicated, isolated container for downloading torrents that guarantees
all traffic goes through the VPN gateway (192.168.1.104). Completed downloads
must be accessible on the NAS at `192.168.1.254:/mnt/data/storage/bittorrent`.

## Approach

Create an LXC running qBittorrent-nox (headless with web UI) that:

1. Uses the VPN gateway (192.168.1.104) as its default gateway
2. Has its own local kill switch that blocks all outbound traffic not routed
   through the VPN gateway, as a second layer on top of the VPN gateway's
   own kill switch
3. Runs a watchdog that monitors the route and kills qBittorrent immediately
   if traffic would exit unencrypted
4. Mounts the NAS via NFS for download storage

**Defense in depth**: even if the VPN gateway's kill switch fails, the
bittorrent LXC's own firewall and watchdog independently prevent any
non-VPN traffic from leaving the container.

## Design

### Container

| Field | Value |
|-------|-------|
| CTID | auto (dynamically allocated from 100+) |
| Hostname | `bittorrent` |
| IP | `192.168.1.<CTID>/23` |
| Gateway | `192.168.1.104` (VPN gateway, not 192.168.1.1) |
| DNS | `192.168.1.104` (VPN gateway's dnsmasq) |
| Network | `192.168.0.0/23` only |
| Type | LXC (privileged) |
| Template | Debian 12 |
| Resources | 2 vCPU, 1 GB RAM, 8 GB disk |

### Storage

NFS mount:

| Mount | Source | Purpose |
|-------|--------|---------|
| `/mnt/torrents/complete` | `192.168.1.254:/mnt/data/storage/bittorrent/complete` | Completed downloads |
| `/mnt/torrents/incomplete` | `192.168.1.254:/mnt/data/storage/bittorrent/incomplete` | In-progress downloads |

A single NFS mount at `/mnt/torrents` maps to `192.168.1.254:/mnt/data/storage/bittorrent`,
with qBittorrent configured to use the `complete/` and `incomplete/` subdirectories.

### Components

1. **qBittorrent-nox** (headless torrent client with web UI on port 80)
2. **NFS mount** to NAS (auto-mount via fstab)
3. **Local iptables kill switch** (outbound only through 192.168.1.104, everything else dropped)
4. **Watchdog service** (systemd timer that checks the default route and VPN gateway reachability, stops qBittorrent if anything is wrong)

### Local kill switch (iptables)

The container's own firewall ensures traffic can only exit through the VPN
gateway. This is independent of the VPN gateway's kill switch.

```
# Default policies
-P INPUT DROP
-P FORWARD DROP
-P OUTPUT DROP

# Allow loopback
-A INPUT -i lo -j ACCEPT
-A OUTPUT -o lo -j ACCEPT

# NAT: redirect port 80 -> 8080 (non-root can't bind 80)
-t nat -A PREROUTING -i eth0 -p tcp --dport 80 -j REDIRECT --to-port 8080

# Allow established/related
-A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Allow SSH from LAN (management)
-A INPUT -p tcp --dport 22 -j ACCEPT

# Allow qBittorrent web UI from LAN
-A INPUT -p tcp --dport 8080 -j ACCEPT

# OUTPUT: block router (must not bypass VPN), allow everything else.
# Torrent peers have public IPs so we cannot restrict to LAN only.
# Routing sends all traffic through the VPN gateway (192.168.1.104),
# whose kill switch ensures nothing exits unencrypted.
-A OUTPUT -d 192.168.1.1 -j DROP
-A OUTPUT -j ACCEPT
```

### Watchdog

A systemd timer (runs every 60 seconds) that:

1. Checks the default route points to 192.168.1.104
2. Pings 192.168.1.104 to verify the VPN gateway is reachable
3. If either check fails, immediately stops qBittorrent-nox and logs an alert
4. On recovery (gateway reachable, route correct), restarts qBittorrent-nox

### qBittorrent configuration

- **Download path**: `/mnt/torrents/incomplete`
- **Completed path**: `/mnt/torrents/complete`
- **Web UI**: port 80, bound to eth0
- **Network interface binding**: bind to eth0 only (qBittorrent's built-in
  interface binding as a third layer of protection)

### Bootstrap script

`homelab/bootstrap/02-setup-bittorrent.sh` will:

1. Install `qbittorrent-nox`, `nfs-common`
2. Create NFS mount point, configure fstab, mount
3. Configure iptables kill switch (OUTPUT DROP by default, allow only VPN gateway and NAS)
4. Persist iptables rules
5. Configure qBittorrent-nox (download paths, web UI port, interface binding)
6. Install watchdog script and systemd timer
7. Enable and start qBittorrent-nox and watchdog
8. Verify: confirm default route is 192.168.1.104, NFS is mounted, web UI is reachable

### Proxmox LXC creation

Container creation is handled by `pve-create-homelab.sh`, which allocates CTIDs dynamically from 100+ and configures networking automatically.

### Accessing the web UI

From any device on the LAN: `http://192.168.1.<CTID>`

## Trade-offs

- **Three layers of VPN enforcement**: VPN gateway kill switch, local iptables kill switch, qBittorrent interface binding. Any single layer failing is caught by the others.
- **Watchdog latency**: the 60-second check interval means up to 60 seconds of attempted (but firewalled) traffic before qBittorrent is stopped. The iptables kill switch blocks this traffic immediately; the watchdog is a belt-and-suspenders measure that also stops the process.
- **NFS access**: relies on NAS export permissions (IP-based). Acceptable for a private LAN, but if NAS export rules change, the mount will break silently.
