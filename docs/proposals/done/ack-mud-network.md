# ACK! MUD Isolated Network

> **Historical proposal.** This document records a design as it was proposed and
> implemented at the time. Host identities in the prose have been updated to the
> CTIDs and hostnames currently in use, so the containers named here can still be
> located. Code blocks are left verbatim and still contain the literal addresses
> and CTIDs used at the time -- do not copy them without checking. Some of what is
> described has since changed or been removed; see
> [architecture.md](../../../architecture.md) for what actually runs today.


Implemented. See [homelab/ack/README.md](../../../homelab/ack/README.md).

Separate Proxmox bridge (vmbr2, 10.1.0.0/24) with:
- ack-gateway (CTID 240): NAT + port forwarding (8890-8894 -> MUD :4000)
- 5 MUD servers (CTIDs 241-245): acktng, ack431, ack42, ack41, assault30
- ack-web (CTID 247): AHA web frontend (aha.ackmud.com)
- apt-cache tri-homed (CT 140 `tierA-5080` `apt-cache`) for package caching
- obs tri-homed (CT 104 `obs`) for observability
- Complete isolation from WOL (vmbr1) and home LAN services
