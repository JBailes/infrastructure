# WOL Proxmox Deployment

## Prerequisites

- Proxmox VE 8.x host at 192.168.1.253
- `vmbr0` (public bridge) connected to a physical interface with internet access
- Root SSH access to the Proxmox host

## Quick Start

One command to set up everything:

```bash
./pve-setup.sh
```

Or exclude specific environments:

```bash
./pve-setup.sh --skip-env test       # Deploy shared + prod (skip test)
./pve-setup.sh --only-env prod       # Deploy shared + prod only
./pve-setup.sh --only-shared         # Deploy shared infrastructure only
```

`pve-setup.sh` is the single orchestrator that handles three phases:
1. Proxmox host preparation (bridges, IP forwarding, SSH key, templates)
2. Container/VM creation (with bridge assignments)
3. Bootstrap deployment (root CA, SPIRE tokens, cert enrollment, services)

Proxmox host observability (pve-exporter, promtail) is managed separately by
`homelab/bootstrap/09-setup-proxmox-obs.sh`.

## Multi-Environment Architecture

The infrastructure supports two environments (prod and test) on a single Proxmox host,
isolated using two separate bridges:

| Bridge | Subnet | Hosts |
|--------|--------|-------|
| vmbr1 | 10.0.0.0/24 | Prod-only hosts + shared hosts (prod interface) |
| vmbr3 | 10.0.1.0/24 | Test-only hosts + shared hosts (test interface) |

Shared hosts are dual-homed on both bridges so they are reachable from either environment.
CTIDs are allocated dynamically from 200+ by `pve-create-hosts.sh`. After
creation, all scripts resolve CTIDs by hostname via `pct list`/`qm list`.

The gateways provide NAT for both subnets but do not route between them,
so prod hosts cannot communicate with test hosts. No VLANs are used. Both environments share
accounts, PKI, observability, and the connection interface.

Players choose their realm (prod or test) at login via the shared connection interface (wol-a).

## What each script does

| Script | Purpose |
|--------|---------|
| **`pve-setup.sh`** | **Single orchestrator: runs all phases (host prep, create, deploy). Start here.** |
| `00-setup-proxmox-host.sh` | Creates private bridges (vmbr1 for prod/shared, vmbr3 for test), enables IP forwarding, generates SSH key, downloads LXC template and cloud image |
| `pve-create-hosts.sh` | Creates LXC containers and the spire-server VM. Supports `--env prod`/`--env test`. Assigns bridge interfaces (dual-bridge for shared hosts). |
| `pve-deploy.sh` | Runs bootstrap scripts in order. Supports `--env prod`/`--env test`. Automates root CA, SPIRE tokens, cert enrollment. |
| `pve-root-ca.sh` | Manages the offline root CA container (generate, sign, destroy). Called automatically by pve-deploy.sh. |
| `pve-destroy-hosts.sh` | Stops and destroys hosts. Supports `--env prod`/`--env test` for per-environment teardown. |
| `pve-audit-hosts.sh` | Drift audit: compares live Proxmox config vs inventory. Use `--strict` for CI gates. |

## Selective execution

```bash
# Deploy a specific environment (pve-deploy.sh still uses --env for filtering)
./pve-deploy.sh --env prod          # Prod only (shared must be up)
./pve-deploy.sh --env test          # Test only (shared must be up)

# Filtering within a sequence
./pve-deploy.sh --from 07           # Resume from step 07 (shared)
./pve-deploy.sh --step 10           # Run only step 10 (shared)
./pve-deploy.sh --host wol-accounts # Run all steps for one host (searches all sequences)
./pve-deploy.sh --force             # Override dependency check
./pve-deploy.sh --scrub             # Remove leftover secret files from all hosts
```

## Teardown

```bash
./pve-destroy-hosts.sh              # Destroy everything (with confirmation)
./pve-destroy-hosts.sh --env test   # Destroy only test environment hosts
./pve-destroy-hosts.sh --env prod   # Destroy only prod environment hosts
./pve-destroy-hosts.sh --host db    # Destroy a single host
./pve-destroy-hosts.sh --yes        # Skip confirmation prompt
```

## Re-signing intermediates

If intermediate CA certs need rotation:

```bash
./pve-root-ca.sh sign     # Brings CA container online for updates, then offline to sign
./pve-root-ca.sh destroy  # Remove the CA container entirely
```

## Bootstrap script layout

```
bootstrap/
  lib/common.sh              # Shared library (networking, users, .NET, firewall, cert enrollment)
  00-setup-gateway.sh        # Shared infrastructure scripts (00-19)
  02-setup-spire-db.sh
  02-setup-wol-accounts-db.sh
  03-setup-ca.sh
  ...
  enroll-host-certs.sh       # Automated cert enrollment (runs after CA is up)
  19-setup-promtail.sh       # Promtail log shipping (runs on all hosts)
  prod/                      # Self-contained prod environment scripts
    11-register-workload-entries-prod.sh
    12-setup-wol-world-db-prod.sh
    13-setup-wol-world-prod.sh
    14-setup-wol-realm-prod.sh
    16-setup-wol-ai-prod.sh
  test/                      # Self-contained test environment scripts
    11-register-workload-entries-test.sh
    12-setup-wol-world-db-test.sh
    13-setup-wol-world-test.sh
    14-setup-wol-realm-test.sh
    16-setup-wol-ai-test.sh
```

Per-env scripts are fully self-contained with hardcoded environment-specific values.
They source `lib/common.sh` for shared functions (networking, users, .NET, firewall,
proxy configuration, cert enrollment, etc.).

Generic scripts (`09-setup-spire-agent.sh`, `19-setup-promtail.sh`, `enroll-host-certs.sh`)
are shared across all environments since they are environment-agnostic.

## Certificate enrollment

Certificate enrollment is fully automated via `enroll-host-certs.sh`:

- **Step 05** (after CA completion): enrolls DB server certs on spire-db and wol-accounts-db
- **Step 19** (after Promtail install): enrolls Promtail client certs on all hosts

The script auto-detects installed services (PostgreSQL, Promtail) and enrolls the
appropriate certificates from the cfssl CA. No manual cert commands are needed.

## Infrastructure (19 hosts)

18 LXC containers + 1 VM (spire-server), CTIDs allocated dynamically from 200+.
See `inventory.conf` for the full host list, bootstrap sequence, and boot ordering.
