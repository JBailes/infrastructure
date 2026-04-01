# Proposal: Deployment Container

**Status:** Complete
**Date:** 2026-03-29
**Affects:** All networks, homelab/bootstrap/, router port forwarding, GitHub Actions

---

## Problem

There is no automated deployment path from GitHub to production. Code changes are merged but reach live services through manual SSH sessions, `pct exec` from the Proxmox host, or ad-hoc file copies. This is slow, error-prone, and requires operator presence.

The infrastructure spans four isolated networks (LAN, WOL prod, WOL test, ACK). A deployment agent needs to reach all of them to build and deploy artifacts across every service.

---

## Goals

1. A dedicated deployment container, quad-homed on all four networks
2. GitHub Actions can SSH in to trigger builds and deployments
3. SSH access severely restricted (key-only, GitHub IP ranges only, dedicated user)
4. Full build environment for all stacks (C, .NET 9, Python 3, Node.js)
5. Deploy artifacts to any service container via SSH

---

## Non-Goals

- CI (test execution). Tests run in GitHub Actions or locally before merge.
- Container creation or Proxmox management. The deploy host builds and pushes artifacts, it does not create or destroy infrastructure.
- Secrets management beyond SSH keys. Service secrets (DB passwords, API keys) remain on their respective hosts.

---

## Host Specification

| Field | Value |
|-------|-------|
| Hostname | `deploy` |
| CTID | 101 |
| Type | LXC (unprivileged) |
| Disk | 32 GB |
| RAM | 2048 MB |
| Cores | 2 |

### Network Interfaces

| Interface | Bridge | IP | Network |
|-----------|--------|-----|---------|
| eth0 | vmbr0 | 192.168.1.101/23 | LAN (internet-facing, SSH ingress) |
| eth1 | vmbr1 | 10.0.0.101/20 | WOL prod |
| eth2 | vmbr2 | 10.1.0.101/24 | ACK |
| eth3 | vmbr3 | 10.0.1.101/24 | WOL test |

Gateway: 192.168.1.1 (via eth0, same as other LAN hosts).

32 GB disk to hold cloned repos, build artifacts, .NET SDK, and Python venvs. 2 GB RAM and 2 cores for parallel .NET and C builds.

---

## SSH Hardening

The deploy host is the only container with internet-facing SSH. Every other host only allows SSH from its local network.

### sshd_config

```
Port 2222
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
AllowUsers deploy
MaxAuthTries 3
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
```

Non-standard port (2222) to reduce scan noise. Only the `deploy` user can log in, only via public key.

### Authorized Keys

The `deploy` user's `~/.ssh/authorized_keys` contains the GitHub Actions deploy key. This key is stored as a GitHub Actions secret in each repo that needs deployment.

Optional `command=` restriction in authorized_keys to limit what the key can execute:

```
command="/opt/deploy/dispatch.sh" ssh-ed25519 AAAA... github-deploy
```

This forces every SSH session through a dispatch script that validates the requested deployment and runs the appropriate build/deploy workflow. No interactive shell access.

### Firewall

```
# Default: drop all inbound
iptables -P INPUT DROP

# Established connections
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -i lo -j ACCEPT

# SSH on :2222 from GitHub Actions IP ranges only (updated periodically)
# GitHub publishes ranges at https://api.github.com/meta ("actions" key)
iptables -A INPUT -i eth0 -p tcp --dport 2222 -m set --match-set github-actions src -j ACCEPT

# SSH on :2222 from LAN (operator access for debugging)
iptables -A INPUT -i eth0 -s 192.168.1.0/23 -p tcp --dport 2222 -j ACCEPT

# SSH from private networks (operator access)
iptables -A INPUT -s 10.0.0.0/20 -p tcp --dport 2222 -j ACCEPT
iptables -A INPUT -s 10.0.1.0/24 -p tcp --dport 2222 -j ACCEPT
iptables -A INPUT -s 10.1.0.0/24 -p tcp --dport 2222 -j ACCEPT
```

The `github-actions` ipset is populated from GitHub's published IP ranges and refreshed by a daily cron job. This narrows the internet-facing attack surface to GitHub's infrastructure.

### Router Port Forwarding

The home router forwards external port 2222 to 192.168.1.101:2222. This is the only new port exposed to the internet.

---

## Build Environment

All stacks needed to build every deployable repo:

| Stack | Packages | Repos |
|-------|----------|-------|
| C | gcc, make, libcrypt-dev, zlib1g-dev, libssl-dev, libpq-dev, liblua5.4-dev, pkg-config | acktng, ack431, ack42, ack41, assault30 |
| .NET 9 | dotnet-sdk-9.0 (via dotnet-install.sh) | wol, wol-realm, wol-accounts, wol-world, wol-ai, web-wol, web-tng |
| Python 3 | python3, python3-pip, python3-venv | tng-ai, tngdb |
| Node.js | nodejs, npm | web-personal |
| Git + SSH | git, openssh-client | all (clone, push artifacts) |

---

## Deployment Model

### Dispatch Script

All deployments route through `/opt/deploy/dispatch.sh`, invoked via the `command=` restriction in authorized_keys. GitHub Actions passes the repo name and ref as environment variables via SSH:

```yaml
# In a GitHub Actions workflow
- name: Deploy
  run: |
    ssh -p 2222 deploy@deploy.example.com "REPO=${{ github.repository }} REF=${{ github.sha }}"
```

The dispatch script:
1. Validates REPO against an allowlist of deployable repos
2. Clones or pulls the repo to `/opt/deploy/repos/<repo-name>`
3. Checks out the specified REF
4. Runs the repo's deploy script (e.g., `deploy.sh` in the repo root)
5. Logs the deployment to `/var/log/deploy/<repo>.log`

### Deploy Scripts (per repo)

Each deployable repo contains a `deploy.sh` at its root that knows how to build and push its artifacts. Examples:

**acktng** (C MUD server):
1. `cd src && make ack`
2. `scp src/ack deploy@10.1.0.241:/opt/mud/src/src/ack`
3. `ssh deploy@10.1.0.241 systemctl restart mud`

**web-tng** (.NET web app):
1. `dotnet publish AckWeb.Api/AckWeb.Api.csproj -c Release -o /tmp/publish`
2. `rsync -a /tmp/publish/ deploy@10.1.0.247:/opt/ack-web/publish/api/`
3. `ssh deploy@10.1.0.247 systemctl restart ackweb`

**tng-ai** (Python service):
1. `rsync -a --exclude='.venv' --exclude='__pycache__' ./ deploy@10.1.0.248:/opt/tng-ai/`
2. `ssh deploy@10.1.0.248 '/opt/tng-ai/.venv/bin/pip install -r /opt/tng-ai/requirements.txt -q'`
3. `ssh deploy@10.1.0.248 systemctl restart tng-ai`

### SSH to Target Containers

The deploy container has an SSH keypair. Its public key is added to a `deploy` user on every target container. This user has permission to restart its service and write to the application directory.

Each target container gets:
- A `deploy` user with limited sudo: `deploy ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart <service>`
- The deploy container's public key in `~deploy/.ssh/authorized_keys`
- Application directory owned by the service user, writable by the `deploy` group

---

## Bootstrap Script

New: `homelab/bootstrap/09-setup-deploy.sh`

1. Disable IPv6
2. Configure DNS (router at 192.168.1.1)
3. Install build tools (C, .NET 9, Python 3, Node.js, Git, SSH)
4. Create `deploy` user (no password, SSH key only)
5. Generate SSH keypair for outbound deployment connections
6. Configure sshd (port 2222, key-only, deploy user only)
7. Install ipset, create `github-actions` ipset from GitHub's API
8. Create cron job to refresh GitHub IP ranges daily
9. Configure iptables (GitHub IPs + LAN on :2222, drop all else)
10. Create `/opt/deploy/dispatch.sh` skeleton
11. DNS entries on all network gateways (ack-gateway, wol-gateways)
12. Promtail for log shipping

---

## Changes

| Location | File | Change |
|----------|------|--------|
| `homelab/bootstrap/` | `09-setup-deploy.sh` | New: deployment container bootstrap |
| `homelab/bootstrap/` | `03-setup-obs.sh` | Add deploy to Prometheus blackbox targets |
| `homelab/bootstrap/` | `08-setup-dashboards.sh` | Add deploy to Homelab Infrastructure panel |
| `homelab/ack/bootstrap/` | `00-setup-ack-gateway.sh` | Add deploy DNS entry (10.1.0.101) |
| `wol/bootstrap/` | `02-setup-wol-gateway.sh` | Add deploy DNS entry (10.0.0.101, 10.0.1.101) |
| `homelab/` | `README.md` | Add deploy to hosts table |
| `architecture.md` | | Add deploy to shared services, guest count |

---

## Execution Order

1. Create CT 119 on Proxmox (quad-homed)
2. Run bootstrap script
3. Add GitHub Actions deploy key to `~deploy/.ssh/authorized_keys`
4. Configure router port forward: external :2222 -> 192.168.1.101:2222
5. Add `deploy` user + SSH key to each target container
6. Add deploy scripts to each repo
7. Create GitHub Actions deployment workflows

Steps 6-7 are per-repo and can be done incrementally.

---

## Trade-offs

**Internet-facing SSH, not a self-hosted runner.** A GitHub Actions self-hosted runner would be outbound-only (no internet-facing port). But it requires a persistent daemon, GitHub org-level configuration, and gives GitHub's runner infrastructure implicit access to the host. Inbound SSH with key restriction and IP allowlisting is simpler, more transparent, and easier to audit. The attack surface is narrow: one port, one user, one key, restricted source IPs.

**Non-standard port 2222.** Does not provide real security (port scans find it), but reduces log noise from automated SSH scanners hitting :22. The actual protection comes from key-only auth and IP restriction.

**ipset for GitHub IPs.** GitHub publishes their Actions IP ranges at `https://api.github.com/meta`. These change periodically, so a cron job refreshes the ipset daily. If the API is unreachable, the existing ipset is preserved (fail-closed for new IPs, fail-open for existing).

**32 GB disk.** Large for an LXC, but needed for .NET SDK (~1 GB), cloned repos, and build artifacts. .NET publish output for multiple services can consume several GB.

**command= restriction in authorized_keys.** Forces all SSH sessions through the dispatch script, preventing arbitrary command execution. The downside is less flexibility for ad-hoc operator use, but operators can SSH in with their own keys (not the GitHub deploy key) for debugging.

**Deploy user on every target container.** Adds a user to ~15 containers. This is the least-privilege approach: the deploy process doesn't need root, just write access to the app directory and permission to restart the service. The alternative (SSH as root) is simpler but violates least privilege.

---

## Status

Pending approval.
