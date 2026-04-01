# WOL Infrastructure

Infrastructure documentation, bootstrap scripts, and deployment configuration for the WOL (World of Legends) game ecosystem.

## Directory Structure

```
wol/
  diagrams.md               # Mermaid infrastructure diagrams
  hosts.md                  # Host inventory reference
  identity-and-auth-contract.md
  ca-inventory.md           # Root CA fingerprint and certificate records
  lint.sh                   # Shellcheck linter for all scripts
  bootstrap/                # Bootstrap scripts (00-20)
    lib/common.sh           # Shared library
    prod/                   # Self-contained prod environment scripts
    test/                   # Self-contained test environment scripts
  config/                   # SPIRE agent/server config templates
  proxmox/                  # Proxmox orchestration scripts
    pve-setup.sh            # Single orchestrator (runs everything)
    inventory.conf          # Host definitions, bootstrap sequences
```

## Infrastructure Overview

WOL runs on a single Proxmox VE host (192.168.1.253) with 13 guests (12 LXC containers + 1 VM) on two isolated private bridges. All services use C#/.NET. All inter-service communication uses mutual TLS. Game clients connect on port 6969.

### Host Inventory

**Shared infrastructure (CTIDs 200-209, dual-homed on vmbr1 + vmbr3):**

| Prod IP | Test IP | Hostname | Type | Role |
|---------|---------|----------|------|------|
| 10.0.0.204 | 10.0.1.204 | spire-server | VM | SPIRE Server (workload identity, LUKS-encrypted via Clevis/Tang) |
| 10.0.0.203 | 10.0.1.203 | ca | LXC | cfssl CA (PostgreSQL client certs, 7-day lifetime, cron renewal) |
| 10.0.0.205 | - | provisioning | LXC | vTPM Provisioning CA (DevID certs for node attestation) |
| 10.0.0.206 | 10.0.1.206 | wol-accounts-db | LXC | PostgreSQL (wol-accounts) |
| 10.0.0.207 | 10.0.1.207 | wol-accounts | LXC | Account authentication and identity API (C#/.NET) |
| 10.0.0.200 | 10.0.1.200 | wol-gateway-a | LXC | NAT gateway, DNS (dnsmasq), NTP (chrony) |
| 10.0.0.201 | 10.0.1.201 | wol-gateway-b | LXC | NAT gateway, DNS, NTP (active-active with gateway-a) |
| 10.0.0.202 | 10.0.1.202 | spire-db | LXC | PostgreSQL (SPIRE datastore) + Tang (NBDE) |
| 10.0.0.100 | - | obs | LXC | Observability: Loki, Prometheus, Alertmanager, Grafana (dual-homed) |
| 10.0.0.208 | 10.0.1.208 | wol-a | LXC | Connection interface (C#/.NET, dual-homed, port 6969) |
| 10.0.0.209 | 10.0.1.209 | wol-web | LXC | WOL web frontend: ackmud.com (Kestrel on :5000, single-homed) |
| 10.0.0.115 | - | apt-cache | LXC | apt-cacher-ng package cache (tri-homed, managed by homelab) |

**Prod environment (CTIDs 210-214, vmbr1 only):**

| IP | Hostname | Type | Role |
|----|----------|------|------|
| 10.0.0.210 | wol-realm-prod | LXC | Game engine (C#/.NET, internal only) |
| 10.0.0.211 | wol-world-prod | LXC | World prototype data API (C#/.NET) |
| 10.0.0.213 | wol-world-db-prod | LXC | PostgreSQL (wol_world) |
| 10.0.0.212 | wol-ai-prod | LXC | AI/NPC intelligence service (C#/.NET) |
| 10.0.0.214 | wol-realm-db-prod | LXC | PostgreSQL (wol_realm) |

**Test environment (CTIDs 215-219, vmbr3 only):**

| IP | Hostname | Type | Role |
|----|----------|------|------|
| 10.0.1.215 | wol-realm-test | LXC | Game engine (C#/.NET, internal only) |
| 10.0.1.216 | wol-world-test | LXC | World prototype data API (C#/.NET) |
| 10.0.1.218 | wol-world-db-test | LXC | PostgreSQL (wol_world) |
| 10.0.1.217 | wol-ai-test | LXC | AI/NPC intelligence service (C#/.NET) |
| 10.0.1.219 | wol-realm-db-test | LXC | PostgreSQL (wol_realm) |

### Network Architecture

- **Prod bridge (vmbr1, 10.0.0.0/24):** Prod hosts and shared infrastructure. Prod-only hosts (CTIDs 210-214) have a single interface on vmbr1.
- **Test bridge (vmbr3, 10.0.1.0/24):** Test hosts and shared infrastructure. Test-only hosts (CTIDs 215-219) have a single interface on vmbr3.
- **Shared hosts (CTIDs 200-209):** Dual-homed on both vmbr1 and vmbr3, reachable from both subnets. Gateways provide NAT for both subnets but do NOT route between them. Cross-environment isolation is enforced by bridge membership.
- **External network (192.168.0.0/23):** Operator access and external service integration. Only externally-homed hosts (gateways, wol-a, obs, apt-cache) have external interfaces.
- **Externally-homed hosts:** wol-gateway-a/b (NAT), wol-a (game traffic on :6969), obs (Grafana on :80, Loki/Prometheus ingestion from external services), apt-cache (Squid forward proxy on :3128). wol-web is single-homed; TLS termination is handled by nginx-proxy (homelab).

### Security Architecture

**PKI (two-tier, single offline root):**
- Offline root CA signs three intermediates: SPIRE (service SVIDs), cfssl CA (DB certs), vTPM Provisioning CA (node attestation)
- SPIRE issues 1-hour X.509-SVIDs and 5-minute JWT-SVIDs for all service-to-service communication
- cfssl issues 7-day PostgreSQL client/server certificates (cron-renewed)
- All .NET services use the `Spiffe.WorkloadApi` NuGet SDK for mTLS and JWT-SVID auth

**Authentication flow:**
1. mTLS handshake (X.509-SVID, transport layer)
2. JWT-SVID verification (application layer, audience-scoped)
3. SPIFFE ID authorization check (endpoint-level permission matrix)
4. Write endpoints require `jti` claim deduplication (replay protection)

**Revocation:** .NET services check OCSP (fail-closed). PostgreSQL checks CRL (fail-closed, refreshed every 10 minutes).

### API Services

All API services are C#/.NET (ASP.NET Core, Npgsql, Kestrel) on port 8443:

| Service | Database | Purpose |
|---------|----------|---------|
| wol-accounts | wol-accounts-db (10.0.0.206) | Account auth, sessions, login, lockout |
| wol-world | wol-world-db (10.0.0.213) | Areas, rooms, exits, objects, NPCs, resets, shops, scripts |

Each service has a separate migration tool (`dotnet run --project tools/Wol.{Service}.Migrate`) using a dedicated DDL user. Migrations run as a deployment step before the API starts.

### Health Monitoring

Every service exposes a `/health` endpoint on port 8443 (internal network only). Dual-homed services (wol-a, obs) bind `/health` to the internal interface only, not the external.

Every service runs a `DependencyHealthChecker` background service that pings the `/health` endpoint of each dependency every 15 seconds. If a dependency is unreachable, the checker:
- Sets `dependency_up{dependency="<name>"}` gauge to 0 (Prometheus metric)
- Increments `dependency_health_failures_total{dependency="<name>"}` counter
- Logs a warning with the dependency name and error

Dependencies are configured via the `DEPENDENCY_URLS` environment variable: `name1=https://host:port/health,name2=https://host:port/health`

**Service dependency map:**

| Service | Depends on |
|---------|-----------|
| wol-accounts | (DB only) |
| wol-world | (DB only) |
| wol-ai | (no WOL dependencies, external AI API only) |
| wol-realm | wol-accounts, wol-world, wol-ai |
| wol (connection interface) | wol-accounts, wol-world, wol-realm |

Prometheus alert rule:

| Alert | Expression | For | Severity |
|-------|-----------|-----|----------|
| `DependencyDown` | `dependency_up == 0` | 30s | critical |

### Observability

Central observability on obs (10.0.0.100 / 192.168.1.100):

| Component | Port | Purpose |
|-----------|------|---------|
| Loki | 3100 | Log aggregation (Promtail agents push from every host) |
| Prometheus | 9090 | Metrics scraping (all service `/metrics` endpoints) |
| Alertmanager | 9093 | Alert routing (webhook to operator) |
| Grafana | 3000 | Dashboards (external interface for operator access) |

**Dual-network ingestion:** WOL services push over mTLS (internal). External services (192.168.0.0/23, including Proxmox at 192.168.1.253) push over TLS + API key. Promtail on the Proxmox host ships hypervisor logs (VM events, SSH access, pveproxy).

**Retention:** Security events 90 days, application logs 30 days.

### Automated Recovery

Full power-cycle recovery is automatic with no operator intervention:

1. Proxmox restarts all guests in boot order
2. Gateways come up first (NAT, DNS, NTP)
3. spire-db host starts Tang server and PostgreSQL
4. SPIRE Server VM unlocks LUKS via Clevis/Tang, starts issuing SVIDs
5. DB hosts and observability start
6. API services start (SPIRE Agents re-attest from cached SVIDs)
7. Game engine and connection interface start last

All services use `systemd Restart=always`. SPIRE SVIDs are cached across reboots (1-hour service, 24-hour agent lifetime).

### Bootstrap Sequence

Initial deployment is orchestrated by `pve-deploy.sh` on the Proxmox host. The sequence runs 24 steps (00-23) with mandatory operator checkpoints for offline root CA signing (steps 01, 06) and SPIRE join token generation (step 09). After initial bootstrap, all certificate issuance, rotation, and service recovery is fully automatic.

See [diagrams.md](diagrams.md) Section 8 for the full gantt chart.

## Active Proposals

| Proposal | Scope |
|----------|-------|
| [Private CA and Secret Management](proposals/active/Infrastructure/private-ca-and-secret-management.md) | Offline root CA, cfssl CA, cert profiles, TLS policy, incident playbooks |
| [SPIFFE/SPIRE Workload Identity](proposals/active/Infrastructure/spiffe-spire-workload-identity.md) | X.509-SVIDs, JWT-SVIDs, node/workload attestation, trust domain |
| [Proxmox Deployment Automation](proposals/active/Infrastructure/proxmox-deployment-automation.md) | Host provisioning, bootstrap orchestration, boot ordering |
| [WOL Accounts DB and API](proposals/active/Infrastructure/wol-accounts-db-and-api.md) | Account auth, sessions, login, lockout, BCrypt |
| [WOL World DB and API](proposals/active/Infrastructure/wol-world-db-and-api.md) | Areas, rooms, objects, NPCs, resets, bulk snapshot |
| [Observability Stack](proposals/active/Infrastructure/observability-stack.md) | Loki, Prometheus, Alertmanager, Grafana, Promtail |
| [WOL Gateway](proposals/active/Infrastructure/wol-gateway.md) | NAT, DNS, NTP, dual-gateway ECMP |
| [WOL AI Service](proposals/active/Infrastructure/wol-ai-service.md) | AI-powered NPC dialogue |
