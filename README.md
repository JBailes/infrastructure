# wol-docs

Documentation, infrastructure scripts, and deployment configuration.

**[Architecture Overview](architecture.md)** -- single-page view of all three networks, shared services, and how everything fits together on one Proxmox host.

## Projects

### [WOL](wol/)

**Decommissioned.** World of Legends game infrastructure. Ran on Proxmox with 19 LXC containers + 1 VM on an isolated private network (10.0.0.0/24, plus a test network on 10.0.1.0/24). Included bootstrap scripts, PKI, SPIRE identity, observability, and multi-environment (prod/test) support. No guests remain on those bridges; the documentation is retained as a design record only.

- [Infrastructure diagrams](wol/diagrams.md)
- [Host inventory](wol/hosts.md)
- [Deployment guide](wol/proxmox/README.md)

### [Homelab](homelab/)

General-purpose homelab services on the home LAN (192.168.1.0/23). Independent of WOL infrastructure.

- [Home LAN diagrams](homelab/diagrams.md) (VPN gateway, bittorrent)
- [Bootstrap scripts](homelab/bootstrap/README.md)

### [ACK! MUDs](homelab/ack/)

Legacy ACK! MUD game servers on an isolated network (`vmbr2`, 10.1.0.0/24). CT 240-250: five MUD servers plus `ackfuss`, a database, a web app, two APIs, and a gateway that forwards game ports (8890-8894).

- [ACK! diagrams](homelab/ack/diagrams.md) (network topology, port forwarding, isolation)
- [Setup guide](homelab/ack/README.md)

## Proposals

Design proposals for both projects live in [proposals/](proposals/).

| Directory | Purpose |
|-----------|---------|
| `proposals/active/` | Approved, currently being implemented |
| `proposals/pending/` | Awaiting review |
| `proposals/complete/` | Fully implemented |
| `proposals/rejected/` | Rejected |
