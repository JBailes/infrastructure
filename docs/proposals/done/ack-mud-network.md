# ACK! MUD Isolated Network

Implemented. See [homelab/ack/README.md](../../homelab/ack/README.md).

Separate Proxmox bridge (vmbr2, 10.1.0.0/24) with:
- ack-gateway (CTID 240): NAT + port forwarding (8890-8894 -> MUD :4000)
- 5 MUD servers (CTIDs 241-245): acktng, ack431, ack42, ack41, assault30
- ack-web (CTID 247): AHA web frontend (aha.ackmud.com)
- apt-cache tri-homed (10.1.0.115) for package caching
- obs tri-homed (10.1.0.100) for observability
- Complete isolation from WOL (vmbr1) and home LAN services
