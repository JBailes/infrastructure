# Proposal: ACK!FUSS 4.4.1 MUD Server

## Status
Approved.

## Problem

The ACK! Historical Archive hosts five MUD servers (acktng, ack431, ack42, ack41, assault30)
but is missing ACK!FUSS 4.4.1, a C/C++ MUD in the ACK lineage that added Lua scripting and
IMC2 inter-MUD communication. The source is available at
`github.com/ackmudhistoricalarchive/ACKFUSS` and should be deployed following the same pattern
as the other legacy MUDs.

## Approach

Add ACK!FUSS as the 6th MUD server on the ACK network.

### Container

| Field | Value |
|-------|-------|
| Hostname | ackfuss |
| CTID | 250 |
| IP | 10.1.0.250 |
| Bridge | vmbr2 |
| Disk | 4 GB |
| RAM | 256 MB |
| Cores | 1 |

### Gateway

External port 8895 on ack-gateway (192.168.1.240) forwards to 10.1.0.250:4000.
Add dnsmasq host entry for ackfuss.

### Build Dependencies

ACKFUSS compiles with g++ (not gcc). The `build-essential` package already provides g++,
so no new packages are needed. The Makefile links against `-lcrypt -lm -lpthread -ldl`.
Lua 5.1 is shipped as a pre-compiled `liblua.a` in the source tree.

### Repo Structure Handling

ACKFUSS has a nested layout: the root Makefile delegates to `ackfuss-4.4.1/src/Makefile`,
the binary lands at `ackfuss-4.4.1/src/ack`, and area files are at `ackfuss-4.4.1/area/`.

The other legacy MUDs have `src/Makefile` directly at the repo root. The `build_source`
and `setup_systemd` functions in `01-setup-ack-mud.sh` need to handle this nested case.

The approach: after cloning, search for the binary and area directory at multiple depths
rather than assuming a fixed layout. This keeps the script generic.

### Monitoring

Promtail deployment already loops over all HOSTS in `pve-setup-ack.sh`, so CT 250 gets
log shipping automatically. The Grafana blackbox probe config in
`homelab/bootstrap/08-setup-dashboards.sh` needs a new TCP target for ackfuss.

## Affected Files

- `homelab/ack/bootstrap/pve-setup-ack.sh`: add ackfuss to HOSTS, mud_hosts, mud_ctids, verify
- `homelab/ack/bootstrap/00-setup-ack-gateway.sh`: add DNAT 8895, dnsmasq entry, summary text
- `homelab/ack/bootstrap/01-setup-ack-mud.sh`: handle nested repo structure in build/systemd
- `homelab/bootstrap/08-setup-dashboards.sh`: add TCP probe for ackfuss

## Trade-offs

- The pre-compiled `liblua.a` (Lua 5.1, x86_64) ships in the repo. If the target architecture
  changes, this would need recompilation. Acceptable for a historical archive deployment.
