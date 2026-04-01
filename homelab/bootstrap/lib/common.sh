#!/usr/bin/env bash
# common.sh -- Shared functions for homelab Proxmox provisioning scripts
# Sourced by homelab bootstrap scripts (00-setup-apt-cache.sh, etc.)

set -euo pipefail

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
warn() { echo "WARN: $*" >&2; }

# ---------------------------------------------------------------------------
# Proxmox infrastructure defaults
# ---------------------------------------------------------------------------

IMAGE_STORAGE="${IMAGE_STORAGE:-isos}"
TEMPLATE="${TEMPLATE:-${IMAGE_STORAGE}:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst}"
STORAGE="${STORAGE:-fast}"
LAN_BRIDGE="vmbr0"
LAN_CIDR=23
ROUTER_GW="192.168.1.1"
PRIVATE_BRIDGE="vmbr1"
ACK_BRIDGE="vmbr2"

# ---------------------------------------------------------------------------
# CTID allocation and resolution
# ---------------------------------------------------------------------------

CTID_RANGE_START=100
VPN_GATEWAY_VMID=104
VPN_GATEWAY_IP="192.168.1.104"
CLOUD_IMAGE_FILENAME="debian-13-genericcloud-amd64.qcow2"
CLOUD_IMAGE_URL="https://cloud.debian.org/images/cloud/trixie/latest/${CLOUD_IMAGE_FILENAME}"
CLOUD_IMAGE_PATH="/mnt/pve/${IMAGE_STORAGE}/template/iso/${CLOUD_IMAGE_FILENAME}"

# Find the first free CTID >= start by querying Proxmox
next_free_ctid() {
    local start="${1:?Usage: next_free_ctid <start>}"
    local used
    used=$(
        { pct list 2>/dev/null | awk 'NR>1{print $1}'; \
          qm list 2>/dev/null | awk 'NR>1{print $1}'; } | sort -n
    )
    local ctid="$start"
    while echo "$used" | grep -qw "$ctid"; do
        ctid=$((ctid + 1))
    done
    echo "$ctid"
}

# Resolve a hostname to its CTID by querying Proxmox
resolve_ctid() {
    local name="${1:?Usage: resolve_ctid <hostname>}"
    local ctid
    ctid=$(pct list 2>/dev/null | awk -v h="$name" '$3 == h {print $1; exit}') || true
    if [[ -n "$ctid" ]]; then echo "$ctid"; return 0; fi
    ctid=$(qm list 2>/dev/null | awk -v h="$name" '$2 == h {print $1; exit}') || true
    if [[ -n "$ctid" ]]; then echo "$ctid"; return 0; fi
    return 1
}

# ---------------------------------------------------------------------------
# CT creation and deployment helpers
# ---------------------------------------------------------------------------

# Create an LXC container. Exits on failure; returns 0 if created, 1 if
# the CT already exists (caller should check and skip post-create steps).
# Usage: create_lxc <ctid> <hostname> <ip> <ram> <cores> <disk> <gw> <privileged> [extra_args...]
create_lxc() {
    local ctid="$1" hostname="$2" ip="$3" ram="$4" cores="$5" disk="$6" gw="$7" priv="$8"
    shift 8

    if pct status "$ctid" &>/dev/null; then
        info "SKIP: CT $ctid ($hostname) already exists"
        return 1
    fi

    local priv_flag="--unprivileged 1"
    [[ "$priv" == "yes" ]] && priv_flag="--unprivileged 0"

    info "Creating CT $ctid ($hostname) at $ip"
    # shellcheck disable=SC2086
    if ! pct create "$ctid" "$TEMPLATE" \
        --hostname "$hostname" \
        --memory "$ram" \
        --cores "$cores" \
        --rootfs "${STORAGE}:${disk}" \
        --net0 "name=eth0,bridge=${LAN_BRIDGE},ip=${ip}/${LAN_CIDR},gw=${gw}" \
        $priv_flag \
        --features nesting=1 \
        "$@" \
        --start 0; then
        err "Failed to create CT $ctid ($hostname)"
    fi
}

# Push a script into a running CT and execute it with --configure.
# Usage: deploy_script <ctid> <local_script_path>
deploy_script() {
    local ctid="$1" script_path="$2"
    local script_name
    script_name=$(basename "$script_path")
    local remote_path="/root/${script_name}"

    pct push "$ctid" "$script_path" "$remote_path" --perms 0755
    pct exec "$ctid" -- bash -c "DEBIAN_FRONTEND=noninteractive TERM=dumb $remote_path --configure"
}

# ---------------------------------------------------------------------------
# VM creation and deployment helpers
# ---------------------------------------------------------------------------

# Create a Debian 13 cloud-init VM. Returns 0 if created, 1 if it already exists.
# Usage: create_vm <vmid> <hostname> <ip> <ram> <cores> <disk> <gw>
create_vm() {
    local vmid="$1" hostname="$2" ip="$3" ram="$4" cores="$5" disk="$6" gw="$7"

    if qm status "$vmid" &>/dev/null; then
        info "SKIP: VM $vmid ($hostname) already exists"
        return 1
    fi

    if [[ ! -f "$CLOUD_IMAGE_PATH" ]]; then
        info "Downloading Debian 13 cloud image..."
        mkdir -p "$(dirname "$CLOUD_IMAGE_PATH")"
        if ! wget -q --show-progress -O "$CLOUD_IMAGE_PATH" "$CLOUD_IMAGE_URL"; then
            rm -f "$CLOUD_IMAGE_PATH"
            err "Failed to download cloud image from $CLOUD_IMAGE_URL"
        fi
        info "Cloud image saved to $CLOUD_IMAGE_PATH"
    fi

    info "Creating VM $vmid ($hostname) at $ip"

    qm create "$vmid" \
        --name "$hostname" \
        --ostype l26 \
        --memory "$ram" \
        --cores "$cores" \
        --scsihw virtio-scsi-single \
        --net0 "virtio,bridge=${LAN_BRIDGE}" \
        --serial0 socket \
        --vga serial0 \
        --agent enabled=1 \
        --onboot 1

    qm importdisk "$vmid" "$CLOUD_IMAGE_PATH" "$STORAGE"
    qm set "$vmid" --scsi0 "${STORAGE}:vm-${vmid}-disk-0,discard=on"
    qm resize "$vmid" scsi0 "${disk}G"

    qm set "$vmid" --ide2 "${STORAGE}:cloudinit"
    qm set "$vmid" \
        --ciuser root \
        --sshkeys /root/.ssh/id_ed25519.pub \
        --ipconfig0 "ip=${ip}/${LAN_CIDR},gw=${gw}" \
        --nameserver "$gw" \
        --ciupgrade 0

    qm set "$vmid" --boot "order=scsi0"
}

# Common SSH options for VM management (accept new host keys automatically)
VM_SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

# Wait for a VM to accept SSH connections.
# Usage: wait_for_vm <vmid> <ip>
wait_for_vm() {
    local vmid="$1" ip="$2"
    local max_wait=120
    local elapsed=0

    info "Waiting for VM $vmid to boot..."
    while [[ $elapsed -lt $max_wait ]]; do
        # shellcheck disable=SC2086
        if ssh $VM_SSH_OPTS "root@${ip}" true 2>/dev/null; then
            info "VM $vmid ($ip) is ready"
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    err "VM $vmid ($ip) did not become reachable within ${max_wait}s"
}

# Push a script into a running VM via SCP and execute it with --configure.
# Usage: deploy_script_vm <ip> <local_script_path>
deploy_script_vm() {
    local ip="$1" script_path="$2"
    local script_name
    script_name=$(basename "$script_path")
    local remote_path="/root/${script_name}"

    # shellcheck disable=SC2086
    scp $VM_SSH_OPTS "$script_path" "root@${ip}:${remote_path}"
    # shellcheck disable=SC2086
    ssh $VM_SSH_OPTS "root@${ip}" "chmod 755 ${remote_path} && DEBIAN_FRONTEND=noninteractive TERM=dumb ${remote_path} --configure"
}
