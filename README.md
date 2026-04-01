# wol-docs

Documentation, infrastructure scripts, and deployment configuration.

**[Architecture Overview](architecture.md)** -- single-page view of all three networks, shared services, and how everything fits together on one Proxmox host.

## Projects

### [WOL](wol/)

World of Legends game infrastructure. Runs on Proxmox with 19 LXC containers + 1 VM on an isolated private network (10.0.0.0/20). Includes bootstrap scripts, PKI, SPIRE identity, observability, and multi-environment (prod/test) support with VLAN isolation.

- [Infrastructure diagrams](wol/diagrams.md)
- [Host inventory](wol/hosts.md)
- [Deployment guide](wol/proxmox/README.md)

### [Homelab](homelab/)

General-purpose homelab services on the home LAN (192.168.1.0/23). Independent of WOL infrastructure.

- [Home LAN diagrams](homelab/diagrams.md) (VPN gateway, bittorrent)
- [Bootstrap scripts](homelab/bootstrap/README.md)

### [ACK! MUDs](homelab/ack/)

Legacy ACK! MUD game servers on an isolated network (`vmbr2`, 10.1.0.0/24). Five MUD servers with a gateway that forwards game ports (8890-8894).

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
