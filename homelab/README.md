# Homelab Infrastructure

General-purpose homelab services on the home LAN (`vmbr0`, 192.168.0.0/23).

Hosts are referred to by **CTID and hostname** (for example CT 108 `bittorrent`), not by IP address. Addresses are assigned at provisioning time and have changed more than once; the CTID and hostname are the stable identifiers. Resolve a current address on the Proxmox host with `pct list` / `qm list`, or with `resolve_ctid <hostname>` from `bootstrap/lib/common.sh`.

> **The bootstrap scripts are out of date with the running host.** Several scripts still hard-code the original CTIDs (see [bootstrap/README.md](bootstrap/README.md#ctid-drift)). The table below reflects what is actually running.

## Services

| CTID | Hostname | Type | Role |
|------|----------|------|------|
| CT 100 | `code` | LXC | Development and tooling container |
| CT 101 | `dns` | LXC | Technitium DNS (:53), admin UI on :5380 |
| CT 102 | `unifi` | LXC | UniFi Network controller (:8443 UI, :8080 inform) + MongoDB |
| CT 103 | `apt-cache` | LXC (dual-homed) | apt-cacher-ng package cache (:3142). Serves LAN and ACK networks. |
| CT 104 | `obs` | LXC (dual-homed) | Loki + Prometheus + Grafana + Alertmanager. Collects logs and metrics from both live networks. |
| CT 105 | `nginx-proxy` | LXC (dual-homed) | nginx reverse proxy + certbot TLS. Routes ackmud.com, bailes.us, and rakuensoftware.com to backends. |
| CT 106 | `personal-web` | LXC | Static file server (node serve on :3000) for bailes.us |
| CT 107 | `rakuen-web` | LXC | Static file server (node serve on :3000) for rakuensoftware.com |
| CT 108 | `bittorrent` | LXC | qBittorrent-nox with triple-layer VPN enforcement. Downloads to NAS via NFS. |
| CT 109 | `deploy` | LXC (dual-homed) | GitHub Actions deployment target over SSH |
| CT 113 | `wolf` | OCI (privileged) | Wolf cloud gaming (Moonlight streaming), GPU passthrough |
| CT 140 | `tierA-5080` | LXC (privileged) | GPU LLM inference host (DHCP addressed) |
| CT 280 | `aimee-main` | LXC | aimee agent host, Docker services on :8443 and :8743 |
| VM 111 | `smoothrouter` | VM | VPN gateway with kill switch. Any device that routes through it gets VPN protection. |

CT 110 is a stopped OCI template, not a running service.

## Test Host (`pvetest`)

`pvetest` is a **second Proxmox host**, not a guest of this one. Agents build
throwaway VMs and containers on it. It holds no persistent workload — everything
on it is test data. Because it is not a guest here, there is no `pct list` entry
to resolve it from; like the router and the NAS, it is named by address
(192.168.1.252) rather than looked up.

Because it is shared and disposable, `pvetest` runs a **test-environment reaper**
(`bootstrap/16-setup-test-host-reaper.sh`). An hourly sweep destroys abandoned
VMs, containers, and scratch directories so the next user always builds on a
clean host rather than inheriting someone else's half-configured box.

A guest is destroyed when **either** clock runs out: no measurable activity for
4h (it is not doing work), or 4h since creation or last renewal (nobody claims
it). A long-running test survives on its own activity; a leased but stalled
environment is still reclaimed. Anyone running a long test renews with
`aimee-keepalive`, which slides the lease a full 4h from the moment of renewal,
uncapped. `aimee-reap-status` shows time left on both clocks.

The rules agents follow live on the host itself at `/root/AGENTS.md`, installed
by the same script. Never adopt an environment already running on pvetest — it
may be destroyed underneath you mid-test.

## Network

All homelab services are on the home LAN (`vmbr0`, 192.168.0.0/23). Four hosts are dual-homed onto the ACK network (`vmbr2`, 10.1.0.0/24):

- **CT 103 `apt-cache`** -- serves packages to both LAN and ACK hosts.
- **CT 104 `obs`** -- Grafana on the LAN interface, log/metric collection from both networks.
- **CT 105 `nginx-proxy`** -- HTTPS on the LAN interface, reaches `ack-web` over the ACK network. Central reverse proxy for all web sites with TLS termination via certbot.
- **CT 109 `deploy`** -- reaches deployment targets on both networks.

> These four were previously tri- or quad-homed onto the WOL networks (`vmbr1`, `vmbr3`) as well. Those interfaces were removed when WOL was decommissioned; the bridges still exist on the host but carry no guests.

VM 111 `smoothrouter` provides a network-level VPN for any device that uses it as a default gateway. CT 108 `bittorrent` routes all traffic through it and has a local kill switch as a second layer.

## ACK! MUD Network

Legacy ACK! MUD game servers on an isolated network (`vmbr2`, 10.1.0.0/24), CT 240-250.

See [ack/README.md](ack/README.md) for details, or run:

```bash
cd ack/bootstrap && ./pve-setup-ack.sh
```

## Setup

See [bootstrap/README.md](bootstrap/README.md) for setup instructions.

## Diagrams

- [Home LAN diagrams](diagrams.md) (VPN gateway, bittorrent, apt-cache)
- [ACK! MUD diagrams](ack/diagrams.md) (MUD network, port forwarding, isolation)
