# infrastructure

Documentation, infrastructure scripts, and deployment configuration for the
Proxmox host at `192.168.1.253`.

**[Architecture Overview](architecture.md)** -- single-page view of both
networks, shared services, and how everything fits together on one Proxmox
host.

## Projects

### [Homelab](homelab/)

General-purpose services on the home LAN (`192.168.0.0/23`). Hosts are
addressed **by name** under the internal `bailes.us` zone -- CTIDs, and
therefore addresses, are allocated dynamically by Terraform.

- [Terraform provisioning](terraform/README.md) -- containers and DNS records
- [Bootstrap scripts](homelab/bootstrap/README.md) -- in-guest configuration
- [Home LAN diagrams](homelab/diagrams.md)

### [ACK! MUDs](homelab/ack/)

Legacy ACK! MUD game servers on an isolated network (`vmbr2`, 10.1.0.0/24).
Six MUD servers with a gateway that forwards game ports (8890-8894), plus a
database, web frontend and two APIs.

- [Setup guide](homelab/ack/README.md) -- includes self-healing and source patches
- [ACK! diagrams](homelab/ack/diagrams.md) (network topology, port forwarding, isolation)

## Removed

The **WOL** game infrastructure (19 guests, `vmbr1`/`vmbr3`, PKI, SPIRE) and
the ***arr media stack** have both been retired. Their design proposals are
kept in `docs/proposals/done/` as a historical record.

## Proposals

Design proposals live in [docs/proposals/](docs/proposals/).

| Directory | Purpose |
|-----------|---------|
| `docs/proposals/pending/` | Awaiting review |
| `docs/proposals/accepted/` | Approved, being implemented |
| `docs/proposals/done/` | Fully implemented (includes retired WOL work) |
| `docs/proposals/rejected/` | Rejected |
| `docs/proposals/deferred/` | Deferred |
