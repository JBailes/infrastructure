# CI/CD Container

## Problem

Builds currently run on the Proxmox host via `pve-build-services.sh`, which requires SSH access to the hypervisor and leaves the .NET SDK installed there. There is no way for GitHub Actions (or equivalent) to trigger deployments, and no isolation between build and host management. ACK services have no automated deploy path at all.

## Proposal

Create a dedicated CI/CD container (LXC) that is quad-homed on all four network bridges. It serves as the single entry point for all automated deployments across every environment.

### Container Spec

| Property | Value |
|---|---|
| Hostname | `cicd` |
| CTID | 119 (homelab range, static) |
| Type | LXC, unprivileged |
| RAM | 2048 MB |
| Cores | 2 |
| Disk | 32 GB |
| eth0 | vmbr0, 192.168.1.119/23 (LAN, SSH ingress from GitHub runner) |
| eth1 | vmbr1, 10.0.0.119/24 (WOL prod/shared) |
| eth2 | vmbr2, 10.1.0.119/24 (ACK) |
| eth3 | vmbr3, 10.0.1.119/24 (WOL test) |

### Software

- .NET 9 SDK (builds WOL and web services)
- GCC/make (builds acktng C code)
- Git + SSH keys for GitHub (clone private repos)
- SSH client (deploy to target hosts)
- No web server, no database, no game services

### Per-Service Deploy Scripts

Each service gets a dedicated deploy script at `/opt/cicd/deploy/`. Scripts are self-contained: clone, build, push, restart, verify, clean up.

```
/opt/cicd/deploy/
  deploy-wol-accounts.sh
  deploy-wol-world-prod.sh
  deploy-wol-world-test.sh
  deploy-wol-realm-prod.sh
  deploy-wol-realm-test.sh
  deploy-wol-web.sh
  deploy-wol-ai-prod.sh      # (when wol-ai repo exists)
  deploy-wol-ai-test.sh
  deploy-acktng.sh
  deploy-ack-web.sh
  deploy-web-personal.sh
  deploy-web-wol.sh           # alias for deploy-wol-web.sh
  lib/common.sh               # shared functions (clone, build, push, health check)
```

Each script follows the same pattern:

1. Clone (or pull) the repo to `/tmp/cicd-build/<service>/`
2. Build (dotnet publish, make, npm build, etc.)
3. SSH to the target host, push the published artifacts
4. Restart the systemd service
5. Health check (poll /health or equivalent for 30s)
6. Clean up build artifacts from `/tmp/cicd-build/`
7. Exit 0 on success, non-zero on failure

Example invocation from a GitHub Action:

```yaml
- name: Deploy wol-realm to test
  run: ssh cicd@192.168.1.119 '/opt/cicd/deploy/deploy-wol-realm-test.sh'
```

### SSH Key Architecture

- The CI/CD container gets its own SSH keypair
- Its public key is added to `authorized_keys` on every target host during bootstrap (new step in enroll-host-certs.sh or a dedicated script)
- GitHub Actions uses a deploy key (stored as a GitHub secret) to SSH into the CI/CD container
- The CI/CD container's GitHub SSH key is read-only (deploy key per repo, or a machine user)

### Firewall

- SSH (22) from LAN (GitHub runner access)
- Outbound SSH to all four networks (deploy to targets)
- Outbound HTTPS to GitHub (git clone)
- No inbound from WOL/ACK/test networks (CI/CD initiates connections, never receives them)

### Bootstrap

New script: `homelab/bootstrap/11-setup-cicd.sh`, following the same pattern as `06-setup-nginx-proxy.sh` (host-side creates the container, container-side configures it).

### What This Replaces

- `pve-build-services.sh` (currently runs on Proxmox host)
- Manual SSH to Proxmox for deployments
- The .NET SDK on the Proxmox host (can be removed after migration)

### What This Does NOT Do

- No CI (test running). Tests run locally on the dev machine or in GitHub Actions.
- No container orchestration. Deployments are direct SSH + systemctl.
- No rollback automation. If a deploy breaks, re-deploy the previous commit.

## Affected Files

- New: `homelab/bootstrap/11-setup-cicd.sh`
- New: `wol-docs/wol/bootstrap/deploy/*.sh` (per-service deploy scripts)
- Modified: `homelab/bootstrap/lib/common.sh` (add cicd container spec)
- Modified: service bootstrap scripts (add cicd SSH key to authorized_keys)
- Removed (after migration): `wol/proxmox/pve-build-services.sh`

## Trade-offs

- Adds one more container to manage, but centralizes all deployment logic
- Quad-homed container has broad network access, so firewall rules matter
- Per-service scripts are more files but each is simple and independently testable
- Build artifacts live on the CI/CD container temporarily, cleaned up per deploy
