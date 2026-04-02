# Proposal: Media Stack Network Security and VPN Egress Hardening

## Problem

The media automation stack (Prowlarr, Sonarr, Radarr, Lidarr, Readarr,
qBittorrent) requires strict network egress controls to ensure all traffic
routes through the existing VPN gateway. Without explicit enforcement:

1. A VPN route failure could silently fall back to the default gateway,
   exposing the real IP.
2. DNS queries could leak outside the VPN tunnel.
3. The gateway at `192.168.1.1` should never be reachable from the media
   stack.
4. Credentials for services are stored in plaintext env files, not a secrets
   mechanism.
5. Inter-service communication lacks least-privilege ACLs.

## Goals

- All media-stack egress provably routes through the VPN path.
- Fail-closed behavior if VPN route is unavailable (no fallback).
- `192.168.1.1/32` is blocked from media-stack egress.
- DNS restricted to approved resolvers only.
- Credentials stored in a secrets mechanism, not plaintext.
- Least-privilege ACLs between services.

## Approach

### 1. VPN kill-switch enforcement

Configure iptables/nftables rules on the media-stack host (or container
network) to drop all egress not routed through the VPN interface:

```bash
# Allow traffic only through tun0 (VPN interface)
iptables -A OUTPUT -o tun0 -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A OUTPUT -d 192.168.1.0/24 -j ACCEPT  # local LAN for service discovery
iptables -A OUTPUT -j DROP  # fail-closed default

# Explicitly block gateway
iptables -A OUTPUT -d 192.168.1.1/32 -j DROP
```

### 2. DNS lockdown

Force all DNS through approved resolvers (e.g., VPN provider DNS or
self-hosted):

```bash
# Block DNS to anything except approved resolvers
iptables -A OUTPUT -p udp --dport 53 -d <approved-resolver> -j ACCEPT
iptables -A OUTPUT -p udp --dport 53 -j DROP
iptables -A OUTPUT -p tcp --dport 53 -d <approved-resolver> -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j DROP
```

### 3. Credential migration

Move service credentials from docker-compose `.env` files to a secrets
backend. Options in order of preference:
- Docker secrets (if using Swarm mode)
- HashiCorp Vault (if already deployed)
- SOPS-encrypted files committed to repo, decrypted at deploy time
- At minimum: file permissions 0600, owned by service user, not in VCS

### 4. Inter-service ACLs

Restrict service-to-service communication to required ports only:

| Source | Destination | Port | Protocol |
|--------|------------|------|----------|
| Sonarr/Radarr/Lidarr/Readarr | qBittorrent WebUI | 8080 | TCP |
| Sonarr/Radarr/Lidarr/Readarr | Prowlarr | 9696 | TCP |
| Prowlarr | Indexers (via VPN) | 443 | TCP |
| qBittorrent | Trackers (via VPN) | * | TCP/UDP |

All other inter-container traffic denied by default.

### 5. Health monitoring

Add a periodic VPN health check that verifies:
- tun0 interface is up
- External IP matches expected VPN exit IP
- `192.168.1.1` is unreachable from media containers

### Changes

| File/System | Change |
|-------------|--------|
| `infrastructure/media-stack/firewall.sh` | VPN kill-switch and DNS lockdown rules |
| `infrastructure/media-stack/docker-compose.yml` | Network isolation, secrets references |
| `infrastructure/media-stack/healthcheck.sh` | VPN and route verification script |

## Acceptance Criteria

- [ ] All media-stack egress routes through VPN (verified by external IP check from container)
- [ ] VPN interface down triggers fail-closed (all egress drops, no fallback)
- [ ] `192.168.1.1` is unreachable from any media-stack container
- [ ] DNS queries only reach approved resolvers
- [ ] No plaintext credentials in docker-compose or env files
- [ ] Inter-service communication limited to required ports
- [ ] Health check script runs on schedule and alerts on drift

## Owner and Effort

- **Owner:** Infra
- **Effort:** M
- **Dependencies:** Existing VPN gateway, existing qBittorrent deployment

## Rollout and Rollback

- **Rollout:** Apply firewall rules, test VPN path, migrate credentials. Can be staged: firewall first, then credentials, then ACLs.
- **Rollback:** Remove firewall rules to restore previous behavior. Credential rollback requires restoring env files from backup.
- **Blast radius:** Overly restrictive rules could block legitimate traffic. Test with each service individually before full rollout.

## Test Plan

- [ ] Verify external IP from inside media container matches VPN exit
- [ ] Simulate VPN interface down, verify all egress fails
- [ ] Verify `curl 192.168.1.1` fails from media container
- [ ] Verify DNS resolution uses only approved resolvers (`dig +trace`)
- [ ] Verify each Arr app can reach qBittorrent and Prowlarr
- [ ] Verify qBittorrent can reach trackers through VPN
- [ ] Manual: attempt to reach a non-VPN destination, confirm blocked

## Operational Impact

- **Metrics:** VPN uptime, route drift events, blocked egress attempts.
- **Logging:** Firewall drop logs for audit trail.
- **Alerts:** VPN interface down, external IP mismatch, route drift detected.
- **Disk/CPU/Memory:** Negligible. Firewall rules are kernel-level.

## Priority

| Item | Priority | Effort | Impact |
|------|----------|--------|--------|
| VPN kill-switch | P0 | S | Prevents IP exposure |
| Gateway block | P0 | S | Explicit security boundary |
| DNS lockdown | P1 | S | Prevents DNS leaks |
| Credential migration | P1 | M | Eliminates plaintext secrets |
| Inter-service ACLs | P2 | S | Defense in depth |

## Trade-offs

**Why iptables over Docker network policies?** iptables rules apply
regardless of Docker networking mode and survive container recreation.
Docker network policies are easier to manage but less granular and depend on
the network driver.

**Why not a dedicated VPN container per service?** A single VPN gateway with
kill-switch rules is simpler to operate and audit than per-service VPN
tunnels. Per-service tunnels add operational complexity with minimal security
benefit when all services share the same VPN exit policy.
