# Convert VPN Gateway from LXC to VM

## Problem

The VPN gateway (CT 104) is an LXC container that forwards LAN traffic through a VPN tunnel. IP forwarding works at the sysctl level, but the shared kernel network namespace prevents the FORWARD chain from receiving transit traffic. Packets from other LAN hosts arrive at the gateway's MAC with non-local destination IPs, but the kernel classifies them as INPUT rather than FORWARD. This is a known limitation of LXC networking.

The result: the kill switch (FORWARD rules) works, but no traffic is actually forwarded through the VPN tunnel.

## Approach

Convert the VPN gateway from a privileged LXC to a Debian 13 cloud-init VM. A VM has its own kernel, so IP forwarding and iptables FORWARD rules work correctly.

### Changes

**`homelab/bootstrap/01-setup-vpn-gateway.sh`**

Host-side (`host_main`):
- Replace `create_lxc` + TUN passthrough with `qm create` + cloud-init
- Import Debian 13 cloud image, configure networking via cloud-init
- Wait for VM boot and cloud-init completion
- Push secrets and deploy script via SSH instead of `pct push`/`pct exec`

In-VM (`configure`):
- Remove `setup_tun()` function (VMs have /dev/net/tun natively)
- Everything else stays the same (openvpn, iptables, dnsmasq, etc.)

**`homelab/bootstrap/lib/common.sh`**

- Add `CLOUD_IMAGE` variable for the Debian 13 genericcloud qcow2 path
- Add `create_vm` helper function (similar to WOL's pve-create-hosts.sh pattern)
- Add `deploy_script_vm` helper to push and execute scripts via SSH
- Rename `VPN_GATEWAY_CTID` to `VPN_GATEWAY_VMID` (still 104)

**Documentation updates**
- `homelab/diagrams.md`: update vpn-gateway type from LXC to VM
- `homelab/README.md`: update type
- `proposals/active/vpn-gateway-lxc.md`: update to reflect VM

### VM spec

| Field | Value |
|-------|-------|
| VMID | 104 |
| Hostname | vpn-gateway |
| IP | 192.168.1.104/23 |
| Gateway | 192.168.1.1 |
| Disk | 4 GB |
| RAM | 512 MB |
| Cores | 1 |
| Image | debian-13-genericcloud-amd64.qcow2 |

### Trade-offs

- VMs use slightly more resources than LXCs (separate kernel, ~100-150 MB base overhead)
- Boot time is slower (cloud-init adds ~30s)
- The fundamental issue (LXC can't forward) has no clean workaround

## Status

Active (implementing).
