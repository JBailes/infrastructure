#!/usr/bin/env bash
# pve-create-hosts.sh -- Create WOL LXC containers and VMs on Proxmox
#
# Runs on: the Proxmox host
# Creates hosts defined in inventory.conf. Create-once: skips existing CTIDs/VMIDs.
# Does not reconcile config changes on existing hosts.
#
# Creation and starting are separate phases:
#   1. All containers/VMs are created (pct create / qm create)
#   2. All are started in parallel (pct start / qm start)
#   3. Wait for all to reach running state
#   4. Run locale-gen on all LXC containers
#
# Usage:
#   ./pve-create-hosts.sh                    # Create shared infrastructure hosts (CTIDs from 200+)
#   ./pve-create-hosts.sh --ctid-start 300   # Start allocating CTIDs from 300
#   ./pve-create-hosts.sh --env prod         # Create prod environment hosts
#   ./pve-create-hosts.sh --env test         # Create test environment hosts
#   ./pve-create-hosts.sh --all              # Create all hosts
#   ./pve-create-hosts.sh --host db          # Create a single host

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

TARGET_HOST=""
TARGET_ENV=""
CREATE_ALL=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host) TARGET_HOST="${2:-}"; [[ -z "$TARGET_HOST" ]] && err "Usage: $0 --host <hostname>"; shift 2 ;;
        --env)  TARGET_ENV="${2:-}"; [[ -z "$TARGET_ENV" ]] && err "Usage: $0 --env <prod|test>"; shift 2 ;;
        --all)  CREATE_ALL=1; shift ;;
        --ctid-start) CTID_RANGE_START="${2:-}"; [[ -z "$CTID_RANGE_START" ]] && err "Usage: $0 --ctid-start <number>"; shift 2 ;;
        *) err "Unknown option: $1" ;;
    esac
done

# Determine which hosts to create based on flags.
# Uses the host's bridge to decide: TEST_BRIDGE = test env, PROD_BRIDGE with
# no test_ip = prod env, PROD_BRIDGE with test_ip = shared.
should_create() {
    local name="$1" bridge="$2" test_ip="$3"
    if [[ -n "$TARGET_HOST" ]]; then
        [[ "$name" == "$TARGET_HOST" ]] && return 0 || return 1
    fi
    if [[ $CREATE_ALL -eq 1 ]]; then
        return 0
    fi
    if [[ -n "$TARGET_ENV" ]]; then
        [[ "$name" == *"-${TARGET_ENV}" ]] && return 0 || return 1
    fi
    # Default: shared hosts only (have test_ip or are on prod bridge without env suffix)
    [[ "$bridge" == "$PROD_BRIDGE" ]] && return 0 || return 1
}

# Track created hosts for the start/locale phases
CREATED_LXCS=()   # "ctid|name|ip" entries
CREATED_VMS=()    # "ctid|name|ip" entries

# ---------------------------------------------------------------------------
# LXC creation (create only, no start)
# ---------------------------------------------------------------------------

create_lxc() {
    parse_host "$1"
    if [[ -z "$H_CTID" || "$H_CTID" == "auto" ]]; then
        H_CTID=$(resolve_ctid "$H_NAME") || true
        if [[ -n "$H_CTID" ]]; then
            info "SKIP: CT $H_CTID ($H_NAME) already exists"
            CREATED_LXCS+=("${H_CTID}|${H_NAME}|${H_IP}")
            return
        fi
        H_CTID=$(next_free_ctid "${CTID_RANGE_START:-200}")
        info "Allocated CTID $H_CTID for $H_NAME"
    elif pct status "$H_CTID" &>/dev/null; then
        info "SKIP: CT $H_CTID ($H_NAME) already exists"
        CREATED_LXCS+=("${H_CTID}|${H_NAME}|${H_IP}")
        return
    fi

    local priv_flag="--unprivileged 1"
    [[ "$H_PRIVILEGED" == "yes" ]] && priv_flag="--unprivileged 0"

    # Determine default gateway based on which bridge the host is on.
    # Test-only hosts (bridge_int = TEST_BRIDGE) use the test gateway.
    local gw="$BOOTSTRAP_GW"
    if [[ "$H_BRIDGE_INT" == "$TEST_BRIDGE" ]]; then
        gw="$BOOTSTRAP_GW_TEST"
    fi

    # Build network arguments.
    # NIC layout depends on the host type:
    #   Public-facing (bridge_ext set): eth0=external, eth1=prod/shared, [eth2=test]
    #   Shared (test_ip set, no ext):   eth0=prod/shared, eth1=test
    #   Per-env (no test_ip, no ext):   eth0=prod or test (single-homed)
    local net_args=""
    local next_nic=0

    if [[ -n "$H_BRIDGE_EXT" ]]; then
        net_args="--net${next_nic} name=eth${next_nic},bridge=${H_BRIDGE_EXT},ip=${H_EXT_IP}/${EXTERNAL_CIDR},gw=${EXTERNAL_GW}"
        next_nic=$((next_nic + 1))
    fi

    # Primary internal NIC (prod/shared bridge, or test bridge for test-only hosts)
    if [[ -n "$H_BRIDGE_EXT" ]]; then
        # Public-facing hosts: internal NIC has no default gateway (ext NIC has it)
        net_args+=" --net${next_nic} name=eth${next_nic},bridge=${H_BRIDGE_INT},ip=${H_IP}/24"
    else
        # Internal-only hosts: internal NIC is the default gateway
        net_args="--net${next_nic} name=eth${next_nic},bridge=${H_BRIDGE_INT},ip=${H_IP}/24,gw=${gw}"
    fi
    next_nic=$((next_nic + 1))

    # Test bridge NIC for shared/dual-homed hosts
    if [[ -n "$H_TEST_IP" ]]; then
        net_args+=" --net${next_nic} name=eth${next_nic},bridge=${TEST_BRIDGE},ip=${H_TEST_IP}/24"
        next_nic=$((next_nic + 1))
    fi

    # nesting=1 is required for systemd 257+ (Debian 13) in all LXC containers.
    # keyctl=1 is needed for privileged containers running SPIRE Agent.
    local features="--features nesting=1"
    if [[ "$H_PRIVILEGED" == "yes" ]]; then
        features="--features nesting=1,keyctl=1"
    fi

    info "Creating CT $H_CTID ($H_NAME) at $H_IP"
    # shellcheck disable=SC2086
    pct create "$H_CTID" "$TEMPLATE_LXC" \
        --hostname "$H_NAME" \
        --ostype debian \
        --storage "$STORAGE" \
        --rootfs "${STORAGE}:${H_DISK_GB}" \
        --memory "$H_RAM_MB" \
        --cores "$H_CORES" \
        --ssh-public-keys "$SSH_PUBLIC_KEY" \
        $features \
        $priv_flag \
        $net_args \
        --onboot 1

    CREATED_LXCS+=("${H_CTID}|${H_NAME}|${H_IP}")
    info "Created CT $H_CTID ($H_NAME)"
}

# ---------------------------------------------------------------------------
# VM creation (create only, no start)
# ---------------------------------------------------------------------------

create_vm() {
    parse_host "$1"
    if [[ -z "$H_CTID" || "$H_CTID" == "auto" ]]; then
        H_CTID=$(resolve_ctid "$H_NAME") || true
        if [[ -n "$H_CTID" ]]; then
            info "SKIP: VM $H_CTID ($H_NAME) already exists"
            CREATED_VMS+=("${H_CTID}|${H_NAME}|${H_IP}")
            return
        fi
        H_CTID=$(next_free_ctid "${CTID_RANGE_START:-200}")
        info "Allocated VMID $H_CTID for $H_NAME"
    elif qm status "$H_CTID" &>/dev/null; then
        info "SKIP: VM $H_CTID ($H_NAME) already exists"
        CREATED_VMS+=("${H_CTID}|${H_NAME}|${H_IP}")
        return
    fi

    [[ -f "$TEMPLATE_VM_CLOUD_IMG" ]] || err "Cloud image not found: $TEMPLATE_VM_CLOUD_IMG (download with: wget -O $TEMPLATE_VM_CLOUD_IMG https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2)"

    info "Creating VM $H_CTID ($H_NAME) via cloud-init"

    # Determine default gateway (test-only VMs use test gateway)
    local vm_gw="$BOOTSTRAP_GW"
    if [[ "$H_BRIDGE_INT" == "$TEST_BRIDGE" ]]; then
        vm_gw="$BOOTSTRAP_GW_TEST"
    fi

    # Create the VM shell (no disks yet, add them in order)
    local vm_create_args=(
        --name "$H_NAME"
        --ostype l26
        --memory "$H_RAM_MB"
        --cores "$H_CORES"
        --scsihw virtio-scsi-single
        --net0 "virtio,bridge=${H_BRIDGE_INT}"
        --serial0 socket
        --vga serial0
        --agent enabled=1
        --onboot 1
    )

    # Add test bridge NIC for dual-homed VMs
    if [[ -n "$H_TEST_IP" ]]; then
        vm_create_args+=(--net1 "virtio,bridge=${TEST_BRIDGE}")
    fi

    qm create "$H_CTID" "${vm_create_args[@]}"

    # Import cloud image as primary disk (becomes disk-0)
    qm importdisk "$H_CTID" "$TEMPLATE_VM_CLOUD_IMG" "$STORAGE"
    qm set "$H_CTID" --scsi0 "${STORAGE}:vm-${H_CTID}-disk-0,discard=on"
    qm resize "$H_CTID" scsi0 "${H_DISK_GB}G"

    # Secondary disk for LUKS (becomes disk-1)
    qm set "$H_CTID" --scsi1 "${STORAGE}:1"

    # TPM state (added after disks so it doesn't take disk-0)
    qm set "$H_CTID" --tpmstate0 "${STORAGE}:4,version=v2.0"

    # Cloud-init drive and network config
    local ipconfig0="ip=${H_IP}/24,gw=${vm_gw}"
    qm set "$H_CTID" --ide2 "${STORAGE}:cloudinit"
    local ci_args=(
        --ciuser root
        --sshkeys "$SSH_PUBLIC_KEY"
        --ipconfig0 "$ipconfig0"
        --nameserver "10.0.0.200 10.0.0.201"
        --ciupgrade 0
    )
    if [[ -n "$H_TEST_IP" ]]; then
        ci_args+=(--ipconfig1 "ip=${H_TEST_IP}/24")
    fi
    qm set "$H_CTID" "${ci_args[@]}"

    # Boot from disk (cloud image is already installed)
    qm set "$H_CTID" --boot "order=scsi0"

    CREATED_VMS+=("${H_CTID}|${H_NAME}|${H_IP}")
    info "Created VM $H_CTID ($H_NAME)"
}

# ---------------------------------------------------------------------------
# Start all hosts sequentially, then wait for running state
#
# Creation does not start hosts. This phase starts them one at a time
# in inventory order (CREATED_LXCS first, then CREATED_VMS) and waits
# for each to reach running state before moving to the next.
# ---------------------------------------------------------------------------

wait_all_running() {
    local all_hosts=("${CREATED_LXCS[@]}" "${CREATED_VMS[@]}")

    for entry in "${all_hosts[@]}"; do
        local ctid name
        IFS='|' read -r ctid name _ <<< "$entry"

        local status
        status=$(pct status "$ctid" 2>/dev/null | awk '{print $2}') || true
        if [[ -z "$status" ]]; then
            status=$(qm status "$ctid" 2>/dev/null | awk '{print $2}') || true
        fi

        if [[ "$status" == "running" ]]; then
            continue
        fi

        if pct status "$ctid" &>/dev/null; then
            info "Starting CT $ctid ($name)..."
            pct start "$ctid" &>/dev/null || true
        elif qm status "$ctid" &>/dev/null; then
            info "Starting VM $ctid ($name)..."
            qm start "$ctid" &>/dev/null || true
        fi

        # Wait for this host to reach running state
        local attempt
        for attempt in $(seq 1 30); do
            status=$(pct status "$ctid" 2>/dev/null | awk '{print $2}') || true
            [[ -z "$status" ]] && status=$(qm status "$ctid" 2>/dev/null | awk '{print $2}') || true
            [[ "$status" == "running" ]] && break
            sleep 2
        done

        if [[ "$status" != "running" ]]; then
            warn "$name ($ctid) not running after 60s (status: $status)"
        fi
    done

    info "All hosts running"
}

# ---------------------------------------------------------------------------
# Run locale-gen on all LXC containers
# ---------------------------------------------------------------------------

configure_locales() {
    info "Generating locales on all containers..."
    for entry in "${CREATED_LXCS[@]}"; do
        local ctid name
        IFS='|' read -r ctid name _ <<< "$entry"
        pct exec "$ctid" -- bash -c "
            sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen 2>/dev/null
            locale-gen en_US.UTF-8 2>/dev/null
            update-locale LANG=en_US.UTF-8 2>/dev/null
        " 2>/dev/null || warn "Locale generation failed on CT $ctid ($name)"
    done
    info "Locale generation complete"
}

# ---------------------------------------------------------------------------
# Wait for VM SSH and cloud-init
# ---------------------------------------------------------------------------

wait_for_vms() {
    for entry in "${CREATED_VMS[@]}"; do
        local ctid name ip
        IFS='|' read -r ctid name ip <<< "$entry"

        info "Waiting for VM $ctid ($name) SSH to become available..."
        local attempts=0
        while ! ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=3 -o BatchMode=yes \
                "root@${ip}" true &>/dev/null; do
            attempts=$((attempts + 1))
            if [[ $attempts -gt 90 ]]; then
                warn "VM $ctid SSH not available after 3 minutes. Check: qm terminal $ctid"
                continue 2
            fi
            sleep 2
        done
        info "VM $ctid ($name) SSH is working"

        info "Waiting for cloud-init to complete on $name..."
        ssh -o StrictHostKeyChecking=accept-new "root@${ip}" \
            "cloud-init status --wait 2>/dev/null || while fuser /var/lib/apt/lists/lock /var/lib/dpkg/lock-frontend 2>/dev/null; do sleep 2; done" \
            || true
        info "VM $ctid ($name) cloud-init complete"
    done
}

# ---------------------------------------------------------------------------
# Boot ordering
# ---------------------------------------------------------------------------

configure_boot_order() {
    info "Configuring Proxmox boot ordering"
    for entry in "${BOOT_ORDER[@]}"; do
        IFS='|' read -r name order delay <<< "$entry"
        local host_entry
        host_entry=$(lookup_host "$name") || { warn "Boot order: host $name not in inventory"; continue; }
        parse_host "$host_entry"
        local startup="order=${order},up=${delay}"
        if [[ "$H_TYPE" == "lxc" ]]; then
            pct set "$H_CTID" --startup "$startup" 2>/dev/null || true
        elif [[ "$H_TYPE" == "vm" ]]; then
            qm set "$H_CTID" --startup "$startup" 2>/dev/null || true
        fi
    done
    info "Boot ordering configured"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    info "WOL Infrastructure Provisioning"
    info "Storage pool: $STORAGE"
    info "CTID range start: ${CTID_RANGE_START:-200}"

    # Phase 1: Create all hosts (no starting)
    info "=== Phase 1: Create containers and VMs ==="
    for entry in "${HOSTS[@]}"; do
        parse_host "$entry"
        should_create "$H_NAME" "$H_BRIDGE_INT" "$H_TEST_IP" || continue

        if [[ "$H_TYPE" == "lxc" ]]; then
            create_lxc "$entry"
        elif [[ "$H_TYPE" == "vm" ]]; then
            create_vm "$entry"
        fi
    done

    # Phase 2: Start all hosts sequentially and wait for running state
    if [[ ${#CREATED_LXCS[@]} -gt 0 || ${#CREATED_VMS[@]} -gt 0 ]]; then
        info "=== Phase 2: Start all hosts ==="
        wait_all_running
    fi

    # Phase 3: Post-start setup
    if [[ ${#CREATED_LXCS[@]} -gt 0 ]]; then
        info "=== Phase 3: Post-start configuration ==="
        configure_locales
    fi

    # Phase 4: Wait for VMs
    if [[ ${#CREATED_VMS[@]} -gt 0 ]]; then
        wait_for_vms
    fi

    # Configure boot ordering
    configure_boot_order

    local total=$((${#CREATED_LXCS[@]} + ${#CREATED_VMS[@]}))
    info "Provisioning complete. $total hosts created/verified."
}

main "$@"
