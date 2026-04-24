# Homelab Infrastructure

General-purpose homelab services running on the same Proxmox host as WOL. These are independent of the WOL game infrastructure and use the home LAN (192.168.0.0/23) directly.

## CTID Allocation

All homelab CTIDs are static and follow the convention `192.168.1.<CTID>` for IP assignment. Each bootstrap script (e.g., `bootstrap/00-setup-apt-cache.sh`) defines its own CTID.

## Services

| Hostname | IP | ID | Type | Role |
|----------|----|------|------|------|
| apt-cache | 192.168.1.115 (vmbr0), 10.0.0.115 (vmbr1), 10.1.0.115 (vmbr2) | 115 | LXC | apt-cacher-ng package cache. Tri-homed: serves LAN, WOL, and ACK networks. |
| obs | 192.168.1.100 (vmbr0), 10.0.0.100 (vmbr1), 10.1.0.100 (vmbr2) | 215 | LXC | Loki + Prometheus + Grafana + Alertmanager. Tri-homed: collects logs and metrics from all networks. |
| vpn-gateway | 192.168.1.104 | 104 | VM | OpenVPN gateway with kill switch. Any device that routes through it gets VPN protection. |
| bittorrent | 192.168.1.116 | 116 | LXC | qBittorrent-nox with triple-layer VPN enforcement. Downloads to NAS via NFS. |
| nginx-proxy | 192.168.1.118 (vmbr0), 10.0.0.118 (vmbr1), 10.1.0.118 (vmbr2) | 118 | LXC | nginx reverse proxy + certbot TLS. Tri-homed: routes ackmud.com, aha.ackmud.com, bailes.us to backends. |
| personal-web | 192.168.1.117 | 117 | LXC | Static file server (node serve on :3000) for bailes.us. |
| wolf | 192.168.1.120 | 120 | LXC | Wolf cloud gaming (Moonlight streaming). Privileged, GPU passthrough. |
| qwen122 | 192.168.1.122 | 122 | LXC | llama.cpp (Vulkan) LLM inference with AMD 7900XTX. Default model Qwen3.6-27B Q4_K_M at 128k context. OpenAI-compatible API on :8080. |

## Network

All homelab services are on the home LAN (`vmbr0`, 192.168.0.0/23). Three hosts are tri-homed:

- **apt-cache** (192.168.1.115): tri-homed on the home LAN, WOL private network (`vmbr1`, 10.0.0.115/20), and ACK private network (`vmbr2`, 10.1.0.115/24) so it can serve packages to all networks.
- **obs** (192.168.1.100): tri-homed on the home LAN (Grafana :80), WOL private network (`vmbr1`, 10.0.0.100/20), and ACK private network (`vmbr2`, 10.1.0.100/24) so it can collect logs and metrics from all networks.
- **nginx-proxy** (192.168.1.118): tri-homed on the home LAN (HTTPS :443), WOL private network (`vmbr1`, 10.0.0.118/20), and ACK private network (`vmbr2`, 10.1.0.118/24). Central reverse proxy for all web sites with TLS termination via certbot.

The VPN gateway provides a network-level VPN for any device that uses it as a default gateway. The bittorrent container routes all traffic through the VPN gateway and has a local kill switch as a second layer.

## ACK! MUD Network

Legacy ACK! MUD game servers on an isolated network (`vmbr2`, 10.1.0.0/24). Completely separate from both WOL and the home LAN.

See [ack/README.md](ack/README.md) for details, or run:

```bash
cd ack/bootstrap && ./pve-setup-ack.sh
```

## Setup

See [bootstrap/README.md](bootstrap/README.md) for setup instructions.

## Diagrams

- [Home LAN diagrams](diagrams.md) (VPN gateway, bittorrent, apt-cache)
- [ACK! MUD diagrams](ack/diagrams.md) (MUD network, port forwarding, isolation)
