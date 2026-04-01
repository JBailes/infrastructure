# Proxmox Deployment Automation

> **Note:** This proposal was written for the original single-environment layout. The infrastructure has since been split into shared, prod (VLAN 10), and test (VLAN 20) environments. All WOL CTIDs are dynamically allocated from 200+. See `infrastructure/proxmox/inventory.conf` and `infrastructure/hosts.md` for the current layout.

**Status:** Pending
**Created:** 2026-03-25

## Problem

The WOL infrastructure consists of 13 hosts (12 LXC containers + 1 VM) that must be created manually in Proxmox, configured with correct networking, and bootstrapped in a specific order. The existing bootstrap scripts (steps 00-20) assume the containers/VMs already exist with the right network interfaces, IPs, and OS. There is no automation for the Proxmox-side provisioning: creating containers, assigning IPs, attaching network bridges, adding disks, or wiring up dual-homed interfaces.

This means deploying the full infrastructure requires an operator to manually create each container/VM in the Proxmox UI or CLI, configure its network, then SSH in and run the bootstrap script. This is error-prone, slow, and undocumented.

## Goals

1. A single configuration file (`inventory.conf`) defining every host's Proxmox parameters (CTID/VMID, IP, type, bridge assignments, disk sizes, privileges, etc.)
2. A Proxmox-side provisioning script (`pve-create-hosts.sh`) that reads the inventory and creates all LXC containers and VMs with correct configuration
3. A deployment orchestrator (`pve-deploy.sh`) that SSHes into each host in bootstrap order and runs the appropriate bootstrap script
4. Create-once safety: re-running provisioning skips hosts that already exist (checked by CTID/VMID); re-running bootstrap scripts is safe (they already handle this internally). **Note:** this is not desired-state convergence. If a host's inventory entry changes (CPU, RAM, disk, network), the existing host is not updated. Config changes to existing hosts require manual intervention or host recreation.
5. A drift-audit tool (`pve-audit-hosts.sh`) that compares live Proxmox host configuration against the inventory and reports mismatches (CPU, RAM, disk, network bridge, privileged flag). This must be run before any deploy and can be wired into release gates to block deploys on drift.

## Non-goals

- Replacing the existing bootstrap scripts (steps 00-20). Those remain unchanged. This proposal adds a layer above them.
- Proxmox cluster management, HA, or live migration.
- Automating the offline root CA steps (01, 06). Those are manual by design.
- Automating join token generation or secret distribution. The deploy script pauses and prompts the operator for secrets at the appropriate steps.

## Proposal

### 1. Inventory configuration

A single bash-sourceable configuration file defines every host. Each host entry specifies everything Proxmox needs to create it.

**`infrastructure/proxmox/inventory.conf`**

```bash
# WOL Infrastructure Inventory
# Sourced by pve-create-hosts.sh and pve-deploy.sh
#
# Format: HOSTS is a bash array. Each element is a pipe-delimited record:
#   name|ctid|type|ip|bridge_int|bridge_ext|privileged|disk_gb|ram_mb|cores|ext_ip|notes
#
# type: lxc or vm
# bridge_int: Proxmox bridge for the private network (e.g. vmbr1)
# bridge_ext: Proxmox bridge for the external network (empty if single-homed)
# privileged: yes or no (LXC only; ignored for VMs)
# ext_ip: external IP for dual-homed hosts (empty if single-homed)

PRIVATE_NET="10.0.0.0/20"
PRIVATE_BRIDGE="vmbr1"
BOOTSTRAP_GW="10.0.0.200"      # Initial default route for single-homed containers (wol-gateway-a).
                               # Bootstrap scripts replace this with ECMP dual-gateway route.
PUBLIC_BRIDGE="vmbr0"
TEMPLATE_LXC="local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst"
TEMPLATE_VM_ISO="local:iso/debian-13.1.0-amd64-netinst.iso"
SSH_PUBLIC_KEY="/root/.ssh/id_ed25519.pub"
EXTERNAL_GW="192.168.1.1"      # External network router
BOOTSTRAP_DIR="/root/aicli/wol-docs/infrastructure/bootstrap"  # Override if scripts are elsewhere
EXTERNAL_CIDR=24
DEFAULT_DISK_GB=8
DEFAULT_RAM_MB=512
DEFAULT_CORES=1

# Shared hosts (CTIDs dynamically allocated from 200+)
HOSTS_SHARED=(
    "wol-gateway-a|auto|lxc|10.0.0.200|${PRIVATE_BRIDGE}|${PUBLIC_BRIDGE}|yes|8|512|1|192.168.1.200|NAT gateway A"
    "wol-gateway-b|auto|lxc|10.0.0.201|${PRIVATE_BRIDGE}|${PUBLIC_BRIDGE}|yes|8|512|1|192.168.1.201|NAT gateway B"
    "spire-server|auto|vm|10.0.0.204|${PRIVATE_BRIDGE}||no|16|1024|2||SPIRE Server (needs secondary disk)"
    "ca|auto|lxc|10.0.0.203|${PRIVATE_BRIDGE}||no|8|512|1||ca intermediate CA"
    "provisioning|auto|lxc|10.0.0.205|${PRIVATE_BRIDGE}||no|4|256|1||vTPM Provisioning CA"
    "wol-accounts|auto|lxc|10.0.0.207|${PRIVATE_BRIDGE}||yes|8|512|1||Accounts API + SPIRE Agent"
    "wol-accounts-db|auto|lxc|10.0.0.206|${PRIVATE_BRIDGE}||no|32|1024|1||PostgreSQL (wol-accounts)"
    "spire-db|auto|lxc|10.0.0.202|${PRIVATE_BRIDGE}||no|32|1024|2||PostgreSQL (SPIRE) + Tang"
    "obs|auto|lxc|10.0.0.100|${PRIVATE_BRIDGE}|${PUBLIC_BRIDGE}|no|64|2048|2|192.168.1.100|Observability (Loki + Prometheus + Grafana)"
    "wol-a|auto|lxc|10.0.0.208|${PRIVATE_BRIDGE}|${PUBLIC_BRIDGE}|yes|8|512|2|192.168.1.208|Connection interface + SPIRE Agent"
)

# Prod environment (VLAN 10, CTIDs dynamically allocated from 200+)
HOSTS_PROD=(
    "wol-realm-prod|auto|lxc|10.0.0.210|${PRIVATE_BRIDGE}||yes|8|1024|2||Game engine + SPIRE Agent (prod)"
    "wol-world-prod|auto|lxc|10.0.0.211|${PRIVATE_BRIDGE}||yes|8|512|1||World API + SPIRE Agent (prod)"
    "wol-world-db-prod|auto|lxc|10.0.0.213|${PRIVATE_BRIDGE}||no|32|1024|1||PostgreSQL world (prod)"
    "wol-ai-prod|auto|lxc|10.0.0.212|${PRIVATE_BRIDGE}||yes|8|512|1||AI service + SPIRE Agent (prod)"
)

# Test environment (VLAN 20, CTIDs dynamically allocated from 200+)
HOSTS_TEST=(
    "wol-realm-test|auto|lxc|10.0.0.215|${PRIVATE_BRIDGE}||yes|8|1024|2||Game engine + SPIRE Agent (test)"
    "wol-world-test|auto|lxc|10.0.0.216|${PRIVATE_BRIDGE}||yes|8|512|1||World API + SPIRE Agent (test)"
    "wol-world-db-test|auto|lxc|10.0.0.218|${PRIVATE_BRIDGE}||no|32|1024|1||PostgreSQL world (test)"
    "wol-ai-test|auto|lxc|10.0.0.217|${PRIVATE_BRIDGE}||yes|8|512|1||AI service + SPIRE Agent (test)"
)

HOSTS=( "${HOSTS_SHARED[@]}" "${HOSTS_PROD[@]}" "${HOSTS_TEST[@]}" )

# Bootstrap sequences: maps step numbers to (host, script) pairs.
# Steps 01 and 06 are offline manual steps and are omitted.

# Shared infrastructure (runs once)
BOOTSTRAP_SHARED=(
    "00|wol-gateway-a|00-setup-gateway.sh|GW_NAME=wol-gateway-a GW_IP=10.0.0.200"
    "00|wol-gateway-b|00-setup-gateway.sh|GW_NAME=wol-gateway-b GW_IP=10.0.0.201"
    "02|spire-db|02-setup-spire-db.sh|"
    "02|wol-accounts-db|02-setup-wol-accounts-db.sh|"
    "03|ca|03-setup-ca.sh|"
    "04|spire-server|04-setup-spire-server.sh|"
    "05|provisioning|05-setup-provisioning-host.sh|"
    # --- PAUSE: operator performs steps 01 + 06 (offline root CA) ---
    "07|ca|07-complete-ca.sh|"
    "08|spire-server|08-complete-spire-server.sh|"
    "09|provisioning|09-complete-provisioning.sh|"
    "10|wol-accounts|10-setup-spire-agent.sh|"
    "10|wol-a|10-setup-spire-agent.sh|"
    "11|wol-accounts|11-setup-wol-accounts.sh|"
    "12|spire-server|12-register-workload-entries.sh|"
    "19|wol-a|19-setup-wol.sh|WOL_NAME=wol-a WOL_IP=10.0.0.208"
    "21|obs|21-setup-obs.sh|"
    "22|wol-accounts|22-setup-promtail.sh|"
    "22|wol-a|22-setup-promtail.sh|"
    "22|spire-db|22-setup-promtail.sh|"
    "22|wol-accounts-db|22-setup-promtail.sh|"
    "22|spire-server|22-setup-promtail.sh|"
    "22|ca|22-setup-promtail.sh|"
    "22|obs|22-setup-promtail.sh|"
    # Step 23 runs directly on the Proxmox host (not in a container)
)

# Prod environment (VLAN 10)
BOOTSTRAP_PROD=(
    "10|wol-realm-prod|10-setup-spire-agent.sh|"
    "10|wol-world-prod|10-setup-spire-agent.sh|"
    "10|wol-ai-prod|10-setup-spire-agent.sh|"
    "13|wol-world-db-prod|13-setup-wol-world-db.sh|"
    "15|wol-world-prod|15-setup-wol-world.sh|"
    "18|wol-realm-prod|18-setup-wol-realm.sh|"
    "20|wol-ai-prod|20-setup-wol-ai.sh|"
    "22|wol-realm-prod|22-setup-promtail.sh|"
    "22|wol-world-prod|22-setup-promtail.sh|"
    "22|wol-world-db-prod|22-setup-promtail.sh|"
    "22|wol-ai-prod|22-setup-promtail.sh|"
)

# Test environment (VLAN 20)
BOOTSTRAP_TEST=(
    "10|wol-realm-test|10-setup-spire-agent.sh|"
    "10|wol-world-test|10-setup-spire-agent.sh|"
    "10|wol-ai-test|10-setup-spire-agent.sh|"
    "13|wol-world-db-test|13-setup-wol-world-db.sh|"
    "15|wol-world-test|15-setup-wol-world.sh|"
    "18|wol-realm-test|18-setup-wol-realm.sh|"
    "20|wol-ai-test|20-setup-wol-ai.sh|"
    "22|wol-realm-test|22-setup-promtail.sh|"
    "22|wol-world-test|22-setup-promtail.sh|"
    "22|wol-world-db-test|22-setup-promtail.sh|"
    "22|wol-ai-test|22-setup-promtail.sh|"
)
```

### 2. Host provisioning script

**`infrastructure/proxmox/pve-create-hosts.sh`**

Runs on the Proxmox host. Creates all LXC containers and VMs defined in the inventory. Create-once: skips hosts whose CTID/VMID already exists. Does not reconcile configuration changes on existing hosts.

**LXC creation** uses `pct create` with:
- Debian 13 template
- Root SSH key injection
- Network interface(s) on the correct bridge(s) with static IPs
- Privileged flag where required
- Disk, RAM, CPU per inventory
- `nesting=1` and `keyctl=1` features for privileged containers (required for systemd and SPIRE)
- Starts the container after creation

**VM creation** (spire-server only) uses `qm create` with cloud-init:
- Debian 13 cloud image imported as primary disk (no manual Debian installation)
- Cloud-init configures root SSH key, static IP, DNS, and package upgrades on first boot
- 1 GB secondary disk at `/dev/sdb` (for LUKS)
- vTPM 2.0 device for SPIRE node attestation
- QEMU Guest Agent for post-boot package installation and SSH host key retrieval
- SSH host key is retrieved via Guest Agent and added to Proxmox `known_hosts` automatically (no TOFU)

**Dual-homed containers** (wol-gateway-a, wol-gateway-b, wol-a) get two `net` entries:
- `net0`: external interface on `PUBLIC_BRIDGE` (static IP from inventory `ext_ip` field, gateway `192.168.1.1`)
- `net1`: internal interface on `PRIVATE_BRIDGE` with static IP

**Single-homed containers** get one `net` entry:
- `net0`: internal interface on `PRIVATE_BRIDGE` with static IP, gateway `BOOTSTRAP_GW` (10.0.0.200, wol-gateway-a; upgraded to ECMP by bootstrap scripts)

#### LXC creation logic

```bash
create_lxc() {
    local name="$1" ctid="$2" ip="$3" bridge_int="$4" bridge_ext="$5"
    local privileged="$6" disk_gb="$7" ram_mb="$8" cores="$9"

    if pct status "$ctid" &>/dev/null; then
        echo "SKIP: CT $ctid ($name) already exists"
        return
    fi

    local priv_flag=""
    if [[ "$privileged" == "yes" ]]; then
        priv_flag="--unprivileged 0"
    else
        priv_flag="--unprivileged 1"
    fi

    local ext_ip="${10}"  # 10th field: explicit external IP for dual-homed hosts

    local net_args=""
    if [[ -n "$bridge_ext" ]]; then
        # Dual-homed: eth0 = external (explicit IP from inventory), eth1 = internal (static)
        net_args="--net0 name=eth0,bridge=${bridge_ext},ip=${ext_ip}/${EXTERNAL_CIDR},gw=${EXTERNAL_GW}"
        net_args+=" --net1 name=eth1,bridge=${bridge_int},ip=${ip}/20"
    else
        # Single-homed: eth0 = internal (static, initial route via BOOTSTRAP_GW)
        net_args="--net0 name=eth0,bridge=${bridge_int},ip=${ip}/20,gw=${BOOTSTRAP_GW}"
    fi

    pct create "$ctid" "$TEMPLATE_LXC" \
        --hostname "$name" \
        --ostype debian \
        --storage fast \
        --rootfs "fast:${disk_gb}" \
        --memory "$ram_mb" \
        --cores "$cores" \
        --ssh-public-keys "$SSH_PUBLIC_KEY" \
        --features nesting=1,keyctl=1 \
        $priv_flag \
        $net_args \
        --start 1

    echo "CREATED: CT $ctid ($name) at $ip"
}
```

#### VM creation logic (spire-server, cloud-init)

```bash
create_vm() {
    # ... (parse host record, skip if exists) ...

    # Create VM shell
    qm create "$vmid" --name "$name" --ostype l26 --memory "$ram_mb" \
        --cores "$cores" --scsihw virtio-scsi-single \
        --net0 "virtio,bridge=${bridge_int}" --serial0 socket --vga serial0 \
        --tpmstate0 "${STORAGE}:4,version=v2.0" --agent enabled=1 --onboot 1

    # Import cloud image as primary disk
    qm importdisk "$vmid" "$TEMPLATE_VM_CLOUD_IMG" "$STORAGE"
    qm set "$vmid" --scsi0 "${STORAGE}:vm-${vmid}-disk-0,discard=on"
    qm resize "$vmid" scsi0 "${disk_gb}G"

    # Secondary disk for LUKS
    qm set "$vmid" --scsi1 "${STORAGE}:1"

    # Cloud-init: SSH key, static IP, DNS
    qm set "$vmid" --ide2 "${STORAGE}:cloudinit"
    qm set "$vmid" --ciuser root --sshkeys "$SSH_PUBLIC_KEY" \
        --ipconfig0 "ip=${ip}/20,gw=${BOOTSTRAP_GW}" \
        --nameserver "10.0.0.200 10.0.0.201" --ciupgrade 1
    qm set "$vmid" --boot "order=scsi0"

    # Start and wait for Guest Agent
    qm start "$vmid"
    # ... (wait loop, install packages via guest agent, retrieve SSH host key) ...
}
```

No manual Debian installation is required. The cloud image boots, cloud-init configures networking and SSH, the Guest Agent allows post-boot package installation and SSH host key retrieval. The entire VM creation is unattended.

### 3. Deployment orchestrator

**`infrastructure/proxmox/pve-deploy.sh`**

Runs on the Proxmox host. Copies bootstrap scripts to each container/VM via `pct push` (LXC) or `scp` (VM), then executes them in bootstrap sequence order.

The orchestrator:
1. Reads `inventory.conf` and `BOOTSTRAP_SEQUENCE`
2. For each step, copies the script to the target host and runs it
3. Passes environment variables where specified (e.g., `GW_NAME`, `JOIN_TOKEN`)
4. Pauses at defined checkpoints for manual intervention (offline CA steps, join token generation)
5. Logs all output to `deploy-YYYY-MM-DD.log` (see log redaction below)

#### Script delivery and execution

For LXC containers, use `pct push` and `pct exec`:

```bash
run_on_lxc() {
    local ctid="$1" script="$2" env_file="$3"
    local script_path="${BOOTSTRAP_DIR}/${script}"
    local remote_path="/root/${script}"

    pct push "$ctid" "$script_path" "$remote_path" --perms 0755
    if [[ -n "$env_file" ]]; then
        # Push env file to a temp path, source it, then remove it.
        # Avoids passing secrets as command-line arguments (visible in /proc).
        # Uses trap to ensure cleanup even if the script fails.
        pct push "$ctid" "$env_file" "/root/.env.bootstrap" --perms 0600
        pct exec "$ctid" -- bash -c "trap 'rm -f /root/.env.bootstrap' EXIT; set -a; source /root/.env.bootstrap; set +a; /root/${script}"
    else
        pct exec "$ctid" -- "/root/${script}"
    fi
}
```

For the VM (spire-server), use SSH. Host key trust is established during VM creation: `pve-create-hosts.sh` retrieves the SSH host key from the VM via the QEMU Guest Agent (`qm guest exec`) after cloud-init completes, and adds it to the Proxmox host's `~/.ssh/known_hosts` automatically. This avoids both manual fingerprint verification and TOFU `ssh-keyscan`, since the Guest Agent channel runs through the hypervisor (not the network). All `ssh`/`scp` calls use `StrictHostKeyChecking=yes`:

```bash
run_on_vm() {
    local ip="$1" script="$2" env_file="$3"
    local script_path="${BOOTSTRAP_DIR}/${script}"

    scp "$script_path" "root@${ip}:/root/${script}"
    if [[ -n "$env_file" ]]; then
        # Copy env file, source it for the script, then remove it.
        # Uses trap to ensure cleanup even if the script fails.
        scp "$env_file" "root@${ip}:/root/.env.bootstrap"
        ssh "root@${ip}" "chmod 600 /root/.env.bootstrap && trap 'rm -f /root/.env.bootstrap' EXIT && set -a && source /root/.env.bootstrap && set +a && /root/${script}"
    else
        ssh "root@${ip}" "/root/${script}"
    fi
}
```

#### Checkpoint pauses

> **Update:** Manual checkpoints have been replaced with automated verification checks in `pve-deploy.sh` (NAT gateway verification, SPIRE agent verification). The deployment runs fully unattended.

The original design paused at defined checkpoints:

| After step | Type | Reason | Operator action |
|------------|------|--------|-----------------|
| 00 (gateways) | verification | Verify NAT works | Test `curl` from any internal host |
| 05 (provisioning) | **mandatory** | Offline CA steps | Perform steps 01 + 06: generate root CA, sign CSRs, distribute certs |
| 09 (complete-provisioning) | **mandatory** | Need join tokens | Generate SPIRE join tokens for each service host |
| 10 (SPIRE agents) | verification | Verify attestation | Confirm all agents are healthy |

Mandatory checkpoints previously required operator action. Verification checkpoints confirmed that a previous step succeeded. Both are now automated:

```bash
checkpoint() {
    local msg="$1"
    local type="${2:-verification}"  # "mandatory" or "verification"
    echo ""
    echo "================================================================"
    echo "CHECKPOINT ($type): $msg"
    echo "================================================================"
    echo ""
    if [[ "$type" == "mandatory" ]]; then
        # Security-critical: always pause, even in unattended mode
        echo "MANDATORY: This checkpoint requires operator action. Cannot be skipped."
        echo "Press Enter to continue, or Ctrl-C to abort."
        read -r
        return
    fi
    if [[ "${UNATTENDED:-0}" == "1" ]]; then
        echo "UNATTENDED: skipping verification checkpoint (logged)"
        return
    fi
    echo "Press Enter to continue, or Ctrl-C to abort."
    read -r
}
```

#### Selective execution

The orchestrator supports running a subset of steps. Before executing, it validates that prerequisite steps have already completed by checking a state file (`deploy-state.log`) written after each successful step. If prerequisites are missing, the orchestrator prints which steps must run first and exits non-zero. The `--force` flag overrides this check for disaster recovery scenarios where the state file is stale or missing:

```bash
# Run everything from the beginning
./pve-deploy.sh

# Run only step 10 (SPIRE agents on all hosts)
./pve-deploy.sh --step 10

# Run from step 07 onward (after offline CA is done)
./pve-deploy.sh --from 07

# Run a single host only
./pve-deploy.sh --host wol-accounts

# Resume from a specific step (for recovery drills or scripted reruns)
./pve-deploy.sh --from 07

# Override dependency check (disaster recovery with stale/missing state file)
./pve-deploy.sh --host wol-accounts --force
```

#### Log redaction

Bootstrap scripts must not echo secret values (tokens, passwords, passphrases). This is the primary control: no secret output at source. All bootstrap scripts are audited for print/echo statements that could leak env vars or arguments. As defence-in-depth, the orchestrator also pipes output through a pattern-based redaction filter (`password=`, `token=`, `secret=`, long base64 sequences) before writing to the deploy log. The pattern filter is a secondary safety net, not the primary mechanism, because pattern-based redaction has inherent false-negative risk with structured formats, multiline values, or unusual key names.

#### Post-deploy secret scrub

After deployment completes (or on abort), the orchestrator runs a scrub pass across all hosts, checking for leftover `.env.bootstrap` files. Shell `trap EXIT` handles normal failures, but hard termination (SIGKILL, power loss) can leave secret files on disk. The scrub pass runs `pct exec <ctid> -- rm -f /root/.env.bootstrap` on each LXC and equivalent over SSH for the VM. It reports per-host status (scrubbed/unreachable/skipped) and the overall deploy is marked as **unsanitized** if any host could not be reached. Unsanitized hosts are logged and must be manually scrubbed before being declared clean. Also available as a standalone command: `./pve-deploy.sh --scrub`.

**Boot-time self-destruct:** Each bootstrap script includes a preamble that deletes `/root/.env.bootstrap` if it exists at script start (before sourcing). This catches files that survived a prior hard termination. Combined with the orchestrator scrub, this provides two independent cleanup paths.

### 4. Network bridge setup

The Proxmox host needs a private bridge for the WOL network. This is a one-time manual setup documented as instructions (not automated, since it modifies the Proxmox host's network config and requires careful consideration of the existing setup).

**`infrastructure/proxmox/README.md`** documents:

```
# Proxmox Network Setup (one-time)

Add to /etc/network/interfaces on the Proxmox host:

    auto vmbr1
    iface vmbr1 inet static
        address 10.0.0.1/20
        bridge-ports none
        bridge-stp off
        bridge-fd 0
        post-up   echo 1 > /proc/sys/net/ipv4/ip_forward
        post-down echo 0 > /proc/sys/net/ipv4/ip_forward

This creates the isolated private bridge. No physical interface is attached
(bridge-ports none), so it is purely internal. The Proxmox host gets 10.0.0.1
as the bridge IP (used as the network gateway in container configs, but NOT
used for internet routing; that goes through wol-gateway-a/b).

The public bridge (vmbr0) should already exist and be connected to the
physical network interface with internet access.

After editing, run: ifreload -a
```

### 5. Gateway single-homed default route

Single-homed containers specify `gw=${BOOTSTRAP_GW}` (10.0.0.200, wol-gateway-a) in their `pct create` network config. This gives them a default route for initial package installation. After both gateways are up and the host's bootstrap script runs, `configure_gateway_route` replaces this with the ECMP dual-gateway route (`ip route add default nexthop via 10.0.0.200 nexthop via 10.0.0.201`).

**During the bootstrap window (before ECMP is configured), if wol-gateway-a is down, single-homed containers lose their default route.** This is acceptable because the bootstrap window is short and operator-supervised. After bootstrap completes, ECMP provides failover to wol-gateway-b.

The gateways (step 00) must be created and running before any other container is started. The provisioning script handles this ordering: it creates the gateway containers first, waits for them to be running, then creates the remaining containers.

### 6. Placement enforcement

The provisioning script validates Proxmox placement rules from `hosts.md`:

- `spire-server` must not share a Proxmox node with `wol-accounts` or `wol-realm-prod`/`wol-realm-test`
- `provisioning` should be on a different node from `spire-server`

**One-workload-per-host enforcement.** The provisioning script validates that each **SPIRE workload host** (hosts that run a SPIRE Agent and have workload registration entries in `12-register-workload-entries.sh`) has exactly one workload SPIFFE ID. If a workload host maps to more than one SPIFFE ID, provisioning fails with an error. This prevents accidental co-location of multiple service identities on a single host, which would negate the SPIFFE identity boundary between them (see spiffe-spire proposal Section 2.1). Infrastructure-only hosts (gateways, ca, provisioning, database hosts) are excluded from this check as they do not run SPIRE workloads.

For single-node Proxmox setups (development/testing), placement rules are logged as warnings but not enforced. The one-workload-per-host rule is always enforced regardless of node count. For multi-node setups, the inventory can specify a `node` field per host.

## File structure

```
infrastructure/proxmox/
    inventory.conf           # Host definitions and bootstrap sequence
    checksums.sha256         # GPG-signed SHA-256 checksums of bootstrap scripts
    checksums.sha256.sig     # Detached GPG signature for checksums manifest
    pve-create-hosts.sh      # Creates all LXC/VM on Proxmox
    pve-deploy.sh            # Runs bootstrap scripts in order
    pve-audit-hosts.sh       # Drift audit: compares live config vs inventory
    README.md                # Proxmox network setup instructions
    lib/
        common.sh            # Shared functions (logging, host lookup, checkpoint)
```

## Bootstrap workflow (operator perspective)

```
1.  Set up Proxmox private bridge (one-time, per README.md)
2.  Review/edit inventory.conf (adjust CTIDs, disk sizes, bridges)
3.  Run: ./pve-create-hosts.sh
        Creates all 12 containers + 1 VM (13 hosts total)
        Starts them all (gateways first)
4.  Run: ./pve-deploy.sh
        Step 00: Runs gateway setup on both gateways
        CHECKPOINT: Verify NAT from an internal host
        Steps 02-05: DB, ca, SPIRE Server, provisioning
        CHECKPOINT: Perform offline root CA steps (01 + 06)
        Steps 07-09: Complete CA hosts
        CHECKPOINT: Generate SPIRE join tokens
        Step 10: SPIRE Agents on all service hosts
        CHECKPOINT: Verify agent attestation
        Steps 11-13: Accounts API, workload registration, players/world DBs
        Steps 14-15: Players/world APIs (after their DBs are ready)
        Steps 18-20: Realm, connection interface, AI
        DONE
```

## Automated power-cycle recovery

The entire infrastructure must recover automatically after a full power loss with no operator intervention. The provisioning script configures Proxmox boot ordering (`onboot: 1` with `startup` delay values) to bring hosts up in dependency order:

| Boot order | Hosts | Reason |
|------------|-------|--------|
| 1 (0s delay) | wol-gateway-a, wol-gateway-b | NAT/DNS/NTP must be up first for all other hosts |
| 2 (5s delay) | spire-db, wol-accounts-db | Tang server (NBDE) and PostgreSQL must be reachable before SPIRE Server can unlock LUKS and connect to its datastore. The spire-db host does not depend on SPIRE (Tang and PostgreSQL use static credentials, not SVIDs). This host is the root of the boot chain. |
| 3 (15s delay) | spire-server | Waits for Tang, unlocks LUKS via Clevis, starts SPIRE Server |
| 4 (30s delay) | ca, provisioning | CA infrastructure |
| 5 (45s delay) | wol-world-db-prod, wol-world-db-test, obs | Database hosts and observability (must be up before their APIs and Promtail agents) |
| 6 (60s delay) | wol-accounts, wol-world-prod, wol-world-test, wol-ai-prod, wol-ai-test | API services (SPIRE Agents re-attest automatically; DBs already running) |
| 7 (75s delay) | wol-realm-prod, wol-realm-test | Game engines (need APIs and DBs) |
| 8 (90s delay) | wol-a | Connection interface (needs realm) |

All services use `systemd Restart=always` so they retry if a dependency is not yet available. The delays are conservative buffers, not hard requirements. SPIRE Agents cache their SVIDs across reboots, so services can start serving on cached credentials while the SPIRE Server is still coming up (1-hour SVID lifetime, 24-hour agent SVID lifetime).

## Trade-offs

**Proxmox API vs CLI.** This proposal uses `pct`/`qm` CLI commands rather than the Proxmox REST API. The CLI is simpler, requires no authentication token management, and runs directly on the Proxmox host where the operator already has shell access. The REST API would be better for remote automation or integration with CI/CD, but that is not a current requirement.

**VM creation via cloud-init.** The spire-server VM uses a Debian 13 cloud image imported as a disk, with cloud-init handling SSH keys, static IP, DNS, and package upgrades automatically on first boot. No manual Debian installation is required. The QEMU Guest Agent is used post-boot to install additional packages (tpm2-tools, chrony, ufw) and retrieve the SSH host key for `known_hosts`. The entire VM creation is unattended and reproducible.

**Single Proxmox node assumption.** The scripts assume all hosts run on one Proxmox node. Multi-node support can be added later by extending the inventory with a `node` field and using `pvesh` for remote creation.

**Default route bootstrapping.** Single-homed containers initially get a default route to `BOOTSTRAP_GW` (10.0.0.200, wol-gateway-a) only. The ECMP dual-gateway route is configured when each host's bootstrap script runs. During this window, if wol-gateway-a is down, single-homed containers have no default route. The provisioning script mitigates this by creating and starting gateway containers first, and the window is short and operator-supervised.

**Script integrity.** Before copying a bootstrap script to a target host, the orchestrator verifies its SHA-256 checksum against a signed manifest (`infrastructure/proxmox/checksums.sha256`). The manifest is GPG-signed by an authorized operator (same keyring used for `ca-inventory.md`). The orchestrator verifies the signature before reading checksums; if the signature is invalid or missing, execution is refused. This prevents a same-host attacker from updating both scripts and manifest to pass validation. The manifest is regenerated and re-signed after any script change: `sha256sum infrastructure/bootstrap/*.sh > checksums.sha256 && gpg --detach-sign checksums.sha256`.

**Root execution model.** All remote execution runs as root via `pct exec` (LXC) or SSH (VM). LXC hosts use `pct exec` through the Proxmox hypervisor API, not SSH. For the spire-server VM (the only SSH target), the orchestrator generates an ephemeral SSH key pair at the start of each deploy run, injects the public key via `qm guest exec` (QEMU Guest Agent), and destroys the private key when the run completes. This limits the window of key validity to the deploy session. The VM's `authorized_keys` is also cleared by the orchestrator at run end. No persistent deployment SSH key exists outside of active runs.

**No secret automation.** Join tokens, DB passwords, and CA passphrases are entered manually at checkpoints. This is intentional: secrets should not be stored in permanent configuration files. When secrets must be passed to a bootstrap script, they are written to a temporary env file (mode 0600) on the target host, sourced by the script, and deleted immediately after. Secrets are never passed as command-line arguments (visible in `/proc` and process listings).

## Affected files

| Location | File | Change |
|----------|------|--------|
| `wol-docs/infrastructure/proxmox/` | `inventory.conf` | New: host inventory and bootstrap sequence |
| `wol-docs/infrastructure/proxmox/` | `pve-create-hosts.sh` | New: Proxmox LXC/VM creation |
| `wol-docs/infrastructure/proxmox/` | `pve-deploy.sh` | New: bootstrap orchestration |
| `wol-docs/infrastructure/proxmox/` | `README.md` | New: Proxmox network bridge setup instructions |
| `wol-docs/infrastructure/proxmox/lib/` | `common.sh` | New: shared functions |
| `wol-docs/infrastructure/` | `hosts.md` | Update: add reference to proxmox/ scripts |
| `wol-docs/infrastructure/bootstrap/` | `00-setup-gateway.sh` | Update: parameterize for GW_NAME/GW_IP (per gateway proposal) |
