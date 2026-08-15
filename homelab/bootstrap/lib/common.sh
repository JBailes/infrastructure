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

# Hosts are named, not numbered. Addresses are looked up from Proxmox at run
# time via host_ip(), so renumbering a guest does not require editing scripts.
# Writing addresses down here is what silently broke the bittorrent watchdog
# and every cross-host reference when the containers were renumbered.
VPN_GATEWAY_HOST="vpn-gateway"
APT_CACHE_HOST="apt-cache"
OBS_HOST="obs"
DNS_HOST="dns"
NAS_HOST="nas"

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

# The NAS is not a Proxmox guest, so its address cannot be derived. It and the
# router are the only host addresses this repo still writes down.
NAS_IP="${NAS_IP:-192.168.1.254}"

# List every guest as "<id> <hostname>", containers and VMs alike.
# Usage: guest_list
guest_list() {
    pct list 2>/dev/null | awk 'NR>1 {print $1, $3}'
    qm list 2>/dev/null | awk 'NR>1 {print $1, $2}'
}

# Print a guest's static IPv4 address, or return 1 if it has none.
# Returns nothing for DHCP or for guests with no network interface, so callers
# can skip them instead of inventing an address.
# Usage: guest_ip <id>
guest_ip() {
    local id="${1:?Usage: guest_ip <id>}"
    local cfg ip
    cfg=$(pct config "$id" 2>/dev/null || qm config "$id" 2>/dev/null) || return 1

    # Matches both shapes pct/qm emit:
    #   LXC: net0: name=eth0,...,ip=<addr>/<prefix>,...
    #   VM:  ipconfig0: ip=<addr>/<prefix>,gw=<addr>
    ip=$(grep -oP '(?<=\bip=)[0-9.]+(?=/)' <<<"$cfg" | head -1)
    [[ -n "$ip" ]] || return 1
    echo "$ip"
}

# Resolve a hostname to its address.
#
# Prefers Proxmox's own view of the guest, which is authoritative and works
# before the resolver is up (and for the resolver itself). Falls back to DNS so
# non-guest names like `nas` still resolve. Callers that need to hand a literal
# address to a container should call this at deploy time rather than baking one
# into the repo.
# Usage: host_ip <hostname>
host_ip() {
    local name="${1:?Usage: host_ip <hostname>}"
    local id ip

    if id="$(resolve_ctid "$name" 2>/dev/null)"; then
        if ip="$(guest_ip "$id" 2>/dev/null)"; then
            echo "$ip"; return 0
        fi
    fi

    ip=$(getent hosts "$name" 2>/dev/null | awk '{print $1; exit}')
    [[ -n "$ip" ]] || return 1
    echo "$ip"
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
