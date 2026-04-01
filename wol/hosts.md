# WOL Infrastructure -- Host Inventory

Prod network: `10.0.0.0/24` (bridge `vmbr1`, prod + shared hosts)
Test network: `10.0.1.0/24` (bridge `vmbr3`, test hosts)
NAT gateways: `10.0.0.200` / `10.0.1.200` (`wol-gateway-a`) and `10.0.0.201` / `10.0.1.201` (`wol-gateway-b`), active-active ECMP for outbound internet

## Environment Isolation

The infrastructure supports two environments (prod and test) on a single Proxmox host,
isolated using two separate bridges:

- **vmbr1** (`10.0.0.0/24`): prod and shared hosts
- **vmbr3** (`10.0.1.0/24`): test hosts

Shared hosts are dual-homed on both bridges so they are reachable from either environment.
The gateways provide NAT for both subnets but do not route between them,
so prod hosts cannot communicate with test hosts and vice versa. No VLANs are used.

## Shared Hosts

| Hostname | IP | Type | Role |
|----------|----|------|------|
| `wol-gateway-a` | `10.0.0.200` + `10.0.1.200` (int), `192.168.1.200` (ext) | LXC (privileged, dual-bridge + ext) | NAT gateway A + DNS (dnsmasq) + NTP (chrony) |
| `wol-gateway-b` | `10.0.0.201` + `10.0.1.201` (int), `192.168.1.201` (ext) | LXC (privileged, dual-bridge + ext) | NAT gateway B + DNS (dnsmasq) + NTP (chrony) |
| `spire-server` | `10.0.0.204` + `10.0.1.204` | **VM** (dual-bridge) | SPIRE Server, CA key on LUKS disk, auto-unlocked via Tang NBDE from `spire-db` |
| `ca` | `10.0.0.203` + `10.0.1.203` | LXC (dual-bridge) | ca intermediate CA |
| `provisioning` | `10.0.0.205` | LXC | vTPM Provisioning CA, network-isolated between provisioning events |
| `wol-accounts` | `10.0.0.207` + `10.0.1.207` | LXC (privileged, dual-bridge) | WOL accounts API (C#/.NET) + SPIRE Agent |
| `wol-accounts-db` | `10.0.0.206` + `10.0.1.206` | LXC (dual-bridge) | PostgreSQL 17 (wol-accounts) |
| `spire-db` | `10.0.0.202` + `10.0.1.202` | LXC (dual-bridge) | PostgreSQL 17 (SPIRE) + Tang server (NBDE) |
| `obs` | `10.0.0.100` (int), `192.168.1.100` (ext), `10.1.0.100` (ACK) | LXC (tri-homed, managed by homelab) | Loki + Prometheus + Grafana + Alertmanager |
| `wol-a` | `10.0.0.208` + `10.0.1.208` (int), `192.168.1.208` (ext) | LXC (privileged, dual-bridge + ext) | WOL connection interface (stateless, autoscalable) + SPIRE Agent |
| `wol-web` | `10.0.0.209` + `10.0.1.209` (int) | LXC (dual-bridge) | WOL web frontend: ackmud.com (.NET Kestrel on :5000, no nginx/TLS) |

## Prod Environment (vmbr1, 10.0.0.0/24)

| Hostname | IP | Type | Role |
|----------|----|------|------|
| `wol-realm-prod` | `10.0.0.210` | LXC (privileged) | WOL game engine (internal only) + SPIRE Agent |
| `wol-world-prod` | `10.0.0.211` | LXC (privileged) | WOL world API (C#/.NET) + SPIRE Agent |
| `wol-world-db-prod` | `10.0.0.213` | LXC | PostgreSQL 17 (wol-world data) |
| `wol-ai-prod` | `10.0.0.212` | LXC (privileged) | WOL AI service (C#/.NET) + SPIRE Agent |
| `wol-realm-db-prod` | `10.0.0.214` | LXC | PostgreSQL 17 (wol-realm data) |

## Test Environment (vmbr3, 10.0.1.0/24)

| Hostname | IP | Type | Role |
|----------|----|------|------|
| `wol-realm-test` | `10.0.1.215` | LXC (privileged) | WOL game engine (internal only) + SPIRE Agent |
| `wol-world-test` | `10.0.1.216` | LXC (privileged) | WOL world API (C#/.NET) + SPIRE Agent |
| `wol-world-db-test` | `10.0.1.218` | LXC | PostgreSQL 17 (wol-world data) |
| `wol-ai-test` | `10.0.1.217` | LXC (privileged) | WOL AI service (C#/.NET) + SPIRE Agent |
| `wol-realm-db-test` | `10.0.1.219` | LXC | PostgreSQL 17 (wol-realm data) |

> **CTID allocation:** WOL hosts use static CTIDs 200-239, assigned in bootstrap order. IPs follow the `X.X.X.{CTID}` convention. ACK hosts use CTIDs 240-254. Homelab hosts use per-service static CTIDs.

> **LXC preference:** `spire-server` is the only VM. It requires a LUKS-encrypted secondary virtual disk
> for `KeyManager "disk"`. All other hosts are LXCs. Privileged LXCs are required for hosts running SPIRE
> Agent so the unix workload attestor can read `/proc/<pid>/exe`.

> **Dual-bridge hosts:** Most shared hosts have interfaces on both vmbr1 (10.0.0.0/24) and vmbr3 (10.0.1.0/24)
> so they are reachable from both prod and test environments. Gateways, wol-a, and wol-web also have external
> interfaces. Both gateways provide NAT for all private hosts (active-active via ECMP).
> wol-a accepts game clients on its external interface (:6969 only) but cannot initiate outbound connections on it.
> `wol-web` is dual-bridge on the private networks; TLS termination is handled by nginx-proxy (homelab).
>
> **apt-cache** (`10.0.0.115`) and **obs** (`10.0.0.100`) are managed by homelab infrastructure, not WOL.
> Both are tri-homed on the home LAN (vmbr0), WOL private network (vmbr1), and ACK private network (vmbr2).
> The WOL orchestrator auto-configures apt proxy if apt-cache is reachable. obs must be deployed before
> WOL Promtail steps so log shipping has a target.

> **wol vs wol-realm:** `wol` is the stateless connection interface (telnet/WSS, autoscalable). `wol-realm` is
> the game engine (internal only). wol instances relay game traffic to wol-realm and call API services directly
> on the private network. Players choose their realm (prod or test) at login.

## Port Reference

| Host | Port | Clients | Purpose |
|------|------|---------|---------|
| `wol-gateway-a/b` | `53` | Both subnets (vmbr1 + vmbr3) | DNS forwarder (dnsmasq) |
| `wol-gateway-a/b` | `123` | Both subnets (vmbr1 + vmbr3) | NTP server (chrony) |
| `spire-server` | `8081` | All SPIRE Agent hosts | Agent-Server gRPC (attestation + SVID issuance) |
| `spire-server` | `8080` | Monitoring | Health check (`/live`, `/ready`) |
| `ca` | `8443` | `spire-db`, `wol-accounts-db`, API service hosts | Cert issuance + renewal (TLS) |
| `spire-db` | `5432` | `spire-server` | PostgreSQL (SPIRE datastore) |
| `spire-db` | `7500` | `spire-server` | Tang (NBDE auto-unlock for SPIRE Server LUKS disk) |
| `wol-accounts-db` | `5432` | `wol-accounts` | PostgreSQL (wol-accounts) |
| `wol-accounts` | `8443` | Private network | Accounts API (mTLS) |
| `wol-world-{prod,test}` | `8443` | Same-env hosts | World API (mTLS) |
| `wol-world-db-{prod,test}` | `5432` | Same-env `wol-world` | PostgreSQL |
| `spire-db`, `wol-accounts-db`, `wol-world-db-{prod,test}` | `9187` | `obs` | postgres_exporter (Prometheus metrics) |
| `wol-ai-{prod,test}` | `8443` | Same-env `wol-realm` | AI API (mTLS) |
| `wol-a` | `6969` | Internet (external) | Game clients (telnet, TLS telnet, WS, WSS) |
| `wol-web` | `5000` | Private network | Kestrel app server (ackmud.com, proxied by nginx-proxy) |

## Bootstrap Order

`01-offline-root-ca-generate.md` and `06-offline-root-ca-sign.md` run on an isolated machine.
All other scripts run on their respective hosts. apt-cache (managed by homelab) should be
deployed first for fast package installs. Both gateways (`00`) must be up before all other
hosts so they can reach the internet.

Bootstrap scripts are organized as:
- `bootstrap/` -- shared infrastructure scripts and base templates
- `bootstrap/prod/` -- self-contained prod environment scripts
- `bootstrap/test/` -- self-contained test environment scripts
- `bootstrap/lib/common.sh` -- shared library (networking, user creation, .NET, firewall, etc.)

| Script | Action | Where |
|--------|--------|-------|
| `00-setup-gateway.sh` | NAT gateway + DNS + NTP + dual-bridge interfaces | `wol-gateway-a`, `wol-gateway-b` |
| `02-setup-spire-db.sh` | Install PostgreSQL (SPIRE) + Tang | `spire-db` |
| `02-setup-wol-accounts-db.sh` | Install PostgreSQL (wol-accounts) | `wol-accounts-db` |
| `03-setup-ca.sh` | Install cfssl, generate intermediate CSR | `ca` |
| `04-setup-spire-server.sh` | LUKS setup, install SPIRE Server, generate SPIRE intermediate CSR | `spire-server` |
| `05-setup-provisioning-host.sh` | Install tooling, generate vTPM Provisioning CA CSR | `provisioning` |
| `06-complete-ca.sh` | Finalize cfssl config, start cfssl serve | `ca` |
| `07-complete-spire-server.sh` | Write SPIRE Server config, start SPIRE Server | `spire-server` |
| `08-complete-provisioning.sh` | Verify Provisioning CA cert | `provisioning` |
| `09-setup-spire-agent.sh` | Install SPIRE Agent with join token | each service host |
| `10-setup-wol-accounts.sh` | Compile C wrapper, set up env, DB cert enrollment | `wol-accounts` |
| `prod/11-register-workload-entries-prod.sh` | Register SPIRE workload entries (prod) | `spire-server` |
| `test/11-register-workload-entries-test.sh` | Register SPIRE workload entries (test) | `spire-server` |
| `prod/12-setup-wol-world-db-prod.sh` | Install PostgreSQL for wol-world (prod) | `wol-world-db-prod` |
| `test/12-setup-wol-world-db-test.sh` | Install PostgreSQL for wol-world (test) | `wol-world-db-test` |
| `prod/13-setup-wol-world-prod.sh` | .NET runtime, DB cert enrollment (prod) | `wol-world-prod` |
| `test/13-setup-wol-world-test.sh` | .NET runtime, DB cert enrollment (test) | `wol-world-test` |
| `prod/14-setup-wol-realm-prod.sh` | .NET 9 runtime, game engine (prod) | `wol-realm-prod` |
| `test/14-setup-wol-realm-test.sh` | .NET 9 runtime, game engine (test) | `wol-realm-test` |
| `15-setup-wol.sh` | .NET 9 runtime, dual-homed networking, :6969 lockdown | `wol-a` |
| `prod/16-setup-wol-ai-prod.sh` | .NET runtime, AI service (prod) | `wol-ai-prod` |
| `test/16-setup-wol-ai-test.sh` | .NET runtime, AI service (test) | `wol-ai-test` |
| _(homelab: 03-setup-obs.sh)_ | Loki + Prometheus + Grafana + Alertmanager (managed by homelab) | `obs` |
| `18-setup-wol-web.sh` | .NET Kestrel app server (WOL web frontend, no nginx/TLS) | `wol-web` |
| `19-setup-promtail.sh` | Promtail log shipper | all service hosts |
| `enroll-host-certs.sh` | Automated cert enrollment (DB server certs, Promtail client certs) | all hosts needing certs |
| _(homelab: 09-setup-proxmox-obs.sh)_ | Proxmox host observability (pve-exporter, promtail) | Proxmox host |

## Proxmox Placement Rules

- `spire-server` must **not** share a Proxmox node with `wol-accounts` or any WOL realm host it certifies.
- `provisioning` should be on a **different** Proxmox node from `spire-server` (Provisioning CA key separation).
- `spire-server` requires a second virtual disk (`/dev/sdb`, minimum 1 GB) added in Proxmox before running its setup script.
- All other LXCs may be placed freely.
