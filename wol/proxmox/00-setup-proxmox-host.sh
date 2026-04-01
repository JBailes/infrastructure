#!/usr/bin/env bash
# 00-setup-proxmox-host.sh -- One-time Proxmox host preparation
#
# Runs on: the Proxmox host (192.168.1.253)
# Run BEFORE pve-create-hosts.sh
#
# Automates:
#   - Private bridge (vmbr1) creation
#   - IP forwarding
#   - SSH key generation (if missing)
#   - LXC template download
#   - Cloud image download (for spire-server VM)

set -euo pipefail

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

[[ $EUID -eq 0 ]] || err "Run as root"

IMAGE_STORAGE="${IMAGE_STORAGE:-isos}"
CLOUD_IMG="/mnt/pve/${IMAGE_STORAGE}/template/iso/debian-13-genericcloud-amd64.qcow2"
LXC_TEMPLATE="debian-13-standard_13.1-2_amd64.tar.zst"

# ---------------------------------------------------------------------------
# Private bridge (vmbr1)
# ---------------------------------------------------------------------------

setup_bridges() {
    local needs_reload=0

    # -----------------------------------------------------------------------
    # vmbr1: WOL prod + shared (10.0.0.0/24)
    # -----------------------------------------------------------------------

    if ! grep -q "iface vmbr1" /etc/network/interfaces 2>/dev/null; then
        cat >> /etc/network/interfaces <<'BRIDGE'

auto vmbr1
iface vmbr1 inet static
    address 10.0.0.1/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0
BRIDGE
        info "vmbr1 added to /etc/network/interfaces (10.0.0.0/24)"
        needs_reload=1
    else
        # Migrate existing vmbr1: remove VLAN-aware config, update to /24
        if grep -q "bridge-vlan-aware" /etc/network/interfaces 2>/dev/null; then
            sed -i '/bridge-vlan-aware/d; /bridge-vids/d' /etc/network/interfaces
            info "Removed VLAN-aware config from vmbr1"
            pvesh set "/nodes/$(hostname)/network/vmbr1" --delete bridge_vlan_aware 2>/dev/null || true
            needs_reload=1
        fi
        if grep -q "10.0.0.1/20" /etc/network/interfaces 2>/dev/null; then
            sed -i 's|10.0.0.1/20|10.0.0.1/24|' /etc/network/interfaces
            info "Updated vmbr1 from /20 to /24"
            needs_reload=1
        fi
        info "vmbr1 already exists"
    fi

    # -----------------------------------------------------------------------
    # vmbr3: WOL test (10.0.1.0/24)
    # -----------------------------------------------------------------------

    if ! grep -q "iface vmbr3" /etc/network/interfaces 2>/dev/null; then
        cat >> /etc/network/interfaces <<'BRIDGE3'

auto vmbr3
iface vmbr3 inet static
    address 10.0.1.1/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0
BRIDGE3
        info "vmbr3 added to /etc/network/interfaces (10.0.1.0/24)"
        needs_reload=1
    else
        info "vmbr3 already exists"
    fi

    if [[ $needs_reload -eq 1 ]] || ! ip link show vmbr1 &>/dev/null || ! ip link show vmbr3 &>/dev/null; then
        ifreload -a
        info "Bridges reloaded"
    fi

    info "Bridge vmbr1 is up (10.0.0.0/24, prod + shared)"
    info "Bridge vmbr3 is up (10.0.1.0/24, test)"
}

# ---------------------------------------------------------------------------
# IP forwarding
# ---------------------------------------------------------------------------

setup_forwarding() {
    if [[ "$(cat /proc/sys/net/ipv4/ip_forward)" == "1" ]]; then
        info "IP forwarding already enabled"
        return
    fi

    info "Enabling IP forwarding"
    echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-ip-forward.conf
    sysctl -p /etc/sysctl.d/99-ip-forward.conf
}

# ---------------------------------------------------------------------------
# SSH key
# ---------------------------------------------------------------------------

setup_ssh_key() {
    if [[ -f /root/.ssh/id_ed25519.pub ]]; then
        info "SSH key already exists"
        return
    fi

    info "Generating SSH key"
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    ssh-keygen -t ed25519 -N "" -f /root/.ssh/id_ed25519
    info "SSH key generated: /root/.ssh/id_ed25519.pub"
}

# ---------------------------------------------------------------------------
# LXC template
# ---------------------------------------------------------------------------

download_lxc_template() {
    if pveam list "$IMAGE_STORAGE" | grep -q "$LXC_TEMPLATE"; then
        info "LXC template already downloaded"
        return
    fi

    info "Downloading LXC template: $LXC_TEMPLATE"
    pveam update
    pveam download "$IMAGE_STORAGE" "$LXC_TEMPLATE"
}

# ---------------------------------------------------------------------------
# Cloud image (for spire-server VM)
# ---------------------------------------------------------------------------

download_cloud_image() {
    if [[ -f "$CLOUD_IMG" ]]; then
        info "Cloud image already downloaded"
        return
    fi

    info "Downloading Debian 13 cloud image"
    mkdir -p "$(dirname "$CLOUD_IMG")"
    wget -O "$CLOUD_IMG" \
        "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
    info "Cloud image saved to $CLOUD_IMG"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    info "Proxmox Host Setup"
    setup_bridges
    setup_forwarding
    setup_ssh_key
    download_lxc_template
    download_cloud_image

    cat <<'EOF'

================================================================
Proxmox host is ready for WOL deployment.

Next steps:
1. Run: ./pve-create-hosts.sh
2. Run: ./pve-deploy.sh

Root CA generation, intermediate signing, SPIRE token distribution,
and cert enrollment are all automated by the deploy script.
================================================================
EOF
}

main "$@"
