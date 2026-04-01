# VPN Gateway LXC

## Problem

To route specific devices' traffic through a VPN, each device must run its own VPN client. This is impractical for devices that don't support VPN clients natively (smart TVs, game consoles, IoT) or when you want centralized control.

## Approach

Create a single LXC container that acts as a network gateway. Any device that sets its default gateway to this container's IP will have all its traffic forwarded through a NordVPN tunnel, transparently. The device itself needs zero VPN configuration.

**Traffic flow:**

```
Device (gateway = vpn-gateway IP)
  -> vpn-gateway LXC (IP forwarding)
    -> tun0 (OpenVPN tunnel to NordVPN)
      -> Internet (encrypted)
```

**Non-VPN traffic flow (unchanged):**

```
Device (gateway = 192.168.1.1)
  -> Standard router
    -> Internet (unencrypted)
```

## Design

### Container

| Field | Value |
|-------|-------|
| CTID | 104 |
| Hostname | `vpn-gateway` |
| IP | `192.168.1.104/23` |
| Gateway | `192.168.1.1` |
| Network | `192.168.0.0/23` only (no internal 10.0.0.0/20 interface) |
| Type | LXC (privileged, for /dev/net/tun access) |
| Template | Debian 12 |
| Resources | 1 vCPU, 256 MB RAM, 2 GB disk |

The container is external-network-only. It exists purely to serve LAN devices on the 192.168.0.0/23 subnet as a VPN gateway and has no role in the WOL internal infrastructure.

### Components

1. **OpenVPN client** connecting to NordVPN (`185.156.175.132:443/tcp`)
2. **IP forwarding** (`net.ipv4.ip_forward = 1`)
3. **iptables NAT masquerade** on `tun0` so return traffic routes back correctly
4. **DNS forwarder** (dnsmasq) forwarding to VPN-pushed DNS servers (prevents DNS leaks)
5. **Kill switch** via iptables: forwarded traffic is only allowed out through `tun0`, never `eth0`. If the tunnel drops, all forwarded traffic is blocked. The gateway's own traffic to the VPN endpoint (`185.156.175.132:443`) is exempted so the tunnel can re-establish.

### Authentication

NordVPN requires `auth-user-pass`. The operator must provide the OpenVPN config and credentials at deploy time (they are never committed to git).

### Deploy prerequisites

Place your VPN provider's files in `homelab/bootstrap/secrets/` (gitignored):

- `client.ovpn` -- the OpenVPN client config (provider-specific, contains certs/keys)
- `auth.txt` -- two lines: service username, then service password

These are pushed onto the container alongside the script at deploy time. See
`homelab/bootstrap/README.md` for the full deployment procedure.

### Bootstrap script

`homelab/bootstrap/01-setup-vpn-gateway.sh` will:

1. Validate that `/root/vpn/client.ovpn` and `/root/vpn/auth.txt` exist
2. Create `/dev/net/tun` device node (required in LXC)
3. Install `openvpn`, `iptables`, `iptables-persistent`, and `dnsmasq`
4. Copy the OpenVPN config and credentials to `/etc/openvpn/` (mode 0600)
5. Remove `/root/vpn/` (secrets no longer needed in staging directory)
6. Enable IP forwarding via sysctl
7. Configure iptables kill switch + NAT masquerade:
   - Default FORWARD policy: DROP
   - Allow FORWARD only on `tun0` (outbound) and established/related return traffic
   - MASQUERADE on `tun0`
   - Persist rules via `iptables-persistent`
8. Configure dnsmasq to listen on eth0, forwarding to VPN-pushed DNS servers (updated dynamically via OpenVPN's `up` script)
9. Enable and start OpenVPN + dnsmasq systemd services
10. Verify the tunnel is up and traffic routes through VPN

### Proxmox LXC creation

The script will include a header comment documenting the `pct create` command:

```bash
# pct create 104 local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst \
#   --hostname vpn-gateway \
#   --memory 256 --cores 1 --rootfs local-lvm:2 \
#   --net0 name=eth0,bridge=vmbr0,ip=192.168.1.104/23,gw=192.168.1.1 \
#   --unprivileged 0 \
#   --features nesting=1 \
#   --start 1
```

Plus the required Proxmox-side LXC config for TUN device passthrough:

```
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
```

### Switching a device to VPN

On any LAN device, change the default gateway from `192.168.1.1` to `192.168.1.104`. That's it. Change it back to `192.168.1.1` to stop using VPN.

## Trade-offs

- **Privileged LXC required**: OpenVPN needs `/dev/net/tun`. A privileged container with the cgroup device allowance is the simplest path in Proxmox LXC.
- **Single server**: The config points to one NordVPN server (`ch217`). If it goes down, the tunnel drops and the kill switch blocks all forwarded traffic until it reconnects.
- **TCP vs UDP**: The NordVPN config uses TCP/443. This works through firewalls but has lower throughput than UDP due to TCP-over-TCP. Fine for general browsing.
