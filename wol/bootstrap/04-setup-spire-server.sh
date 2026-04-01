#!/usr/bin/env bash
# 04-setup-spire-server.sh -- Install SPIRE Server and generate intermediate CSR (10.0.0.204)
#
# Runs on: spire-server (10.0.0.204), Debian 13 VM
# Run order: Step 03 (after spire-db is up with Tang)
#
# Prerequisites:
#   - A second virtual disk added to the VM in Proxmox (min 1 GB)
#     Default assumed path: /dev/sdb (verify with: lsblk)
#   - Tang server running on spire-db (10.0.0.202:7500)
#   - Offline root CA generated (see 01-offline-root-ca-generate.md)
#
# After this script completes:
#   CSR is collected automatically by pve-root-ca.sh
#   Signing is automated by pve-deploy.sh at step 07
#   - Then run: SPIRE_DB_PASSWORD=<pass> ./07-complete-spire-server.sh

set -euo pipefail

_LIB="$(dirname "$0")/lib/common.sh"; [[ -f "$_LIB" ]] || _LIB="/root/lib/common.sh"; source "$_LIB" 2>/dev/null || true

# Boot-time secret scrub: remove leftover .env.bootstrap from prior failed runs
rm -f /root/.env.bootstrap

SPIRE_VERSION="1.10.3"
SPIRE_IP="10.0.0.204"
DB_IP="10.0.0.202"
TANG_URL="http://${DB_IP}:7500"
# Find the 1GB secondary disk (LUKS target) by size, not device name.
# Cloud-init can reorder /dev/sdX devices unpredictably.
find_luks_device() {
    for disk in /dev/sd? /dev/vd?; do
        [[ -b "$disk" ]] || continue
        local size_bytes size_gb
        size_bytes=$(blockdev --getsize64 "$disk" 2>/dev/null) || continue
        size_gb=$(( size_bytes / 1073741824 ))
        # The LUKS disk is 1GB; skip the OS disk (16GB+)
        if [[ $size_gb -le 2 ]]; then
            # Verify it has no partitions and is not mounted
            if [[ $(lsblk -n -o TYPE "$disk" 2>/dev/null | wc -l) -eq 1 ]] \
               && ! lsblk -n -o MOUNTPOINT "$disk" 2>/dev/null | grep -q '/'; then
                echo "$disk"
                return
            fi
        fi
    done
    return 1
}
LUKS_DEVICE="${LUKS_DEVICE:-$(find_luks_device)}" || err "Could not find a small (<2GB) unmounted disk for LUKS. Add a 1GB secondary disk to the VM."
LUKS_NAME="spire-keys"
LUKS_MOUNT="/var/lib/spire/keys"
SPIRE_USER="spire"
SPIRE_CONF_DIR="/etc/spire/server"
SPIRE_DATA_DIR="/var/lib/spire/server"
SPIRE_BIN_DIR="/usr/local/bin"
LOG_DIR="/var/log/spire"

: "${SPIRE_DB_PASSWORD:?Set SPIRE_DB_PASSWORD environment variable}"

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

[[ $EUID -eq 0 ]] || err "Run as root"

# ---------------------------------------------------------------------------
# Phase 1: install, LUKS setup, generate SPIRE intermediate CSR
# ---------------------------------------------------------------------------

main() {
    disable_ipv6
    configure_gateway_route
    configure_dns_ntp
    install_packages
    install_spire
    setup_luks
    setup_user_and_dirs
    generate_spire_intermediate_csr
    configure_firewall
    print_instructions
}

install_packages() {
    info "Installing packages"
    apt-get update -qq
    apt-get install -y --no-install-recommends \
        curl ca-certificates openssl iptables chrony \
        qemu-guest-agent tpm2-tools \
        cryptsetup clevis-luks clevis-systemd \
        initramfs-tools
    systemctl enable --now qemu-guest-agent 2>/dev/null || true
}

install_spire() {
    info "Installing SPIRE $SPIRE_VERSION"
    local tarball="spire-${SPIRE_VERSION}-linux-amd64-musl.tar.gz"
    local url="https://github.com/spiffe/spire/releases/download/v${SPIRE_VERSION}/${tarball}"
    local tmp="/tmp/spire-install"
    mkdir -p "$tmp"
    curl -fsSL --connect-timeout 30 --retry 3 --retry-delay 5 "$url" -o "/tmp/${tarball}"
    tar -xzf "/tmp/${tarball}" -C "$tmp"
    rm -f "/tmp/${tarball}"
    cp "$tmp/spire-${SPIRE_VERSION}/bin/spire-server" "$SPIRE_BIN_DIR/"
    cp "$tmp/spire-${SPIRE_VERSION}/bin/spire-agent"  "$SPIRE_BIN_DIR/"
    chmod 755 "$SPIRE_BIN_DIR/spire-server"
    rm -rf "$tmp"
    info "SPIRE binaries installed to $SPIRE_BIN_DIR"
}

setup_luks() {
    info "Setting up LUKS encrypted disk on $LUKS_DEVICE"
    [[ -b "$LUKS_DEVICE" ]] \
        || err "Block device $LUKS_DEVICE not found. Add a second disk to the VM in Proxmox."

    if cryptsetup status "$LUKS_NAME" &>/dev/null; then
        info "LUKS device $LUKS_NAME already open; skipping format"
    else
        info "Formatting $LUKS_DEVICE with LUKS2 + Argon2id KDF"

        # Generate a random backup passphrase (Tang NBDE is the primary unlock method)
        local passphrase_file="/root/luks-backup-passphrase"
        openssl rand -base64 32 > "$passphrase_file"
        chmod 600 "$passphrase_file"

        cryptsetup luksFormat \
            --type luks2 \
            --pbkdf argon2id \
            --label spire-keys \
            --key-file "$passphrase_file" \
            --batch-mode \
            "$LUKS_DEVICE"

        info "Binding $LUKS_DEVICE to Tang server at $TANG_URL for NBDE auto-unlock"
        clevis luks bind -y -k "$passphrase_file" -d "$LUKS_DEVICE" tang \
            "{\"url\":\"${TANG_URL}\"}"
        info "Tang binding complete"

        info "Backup passphrase saved to $passphrase_file"
        info "Backup passphrase saved. Tang NBDE handles normal unlock automatically."

        # Open the device manually for first use
        cryptsetup luksOpen --key-file "$passphrase_file" "$LUKS_DEVICE" "$LUKS_NAME"
        mkfs.ext4 -L spire-keys "/dev/mapper/${LUKS_NAME}"
        info "LUKS device formatted with ext4"
    fi

    # Mount
    mkdir -p "$LUKS_MOUNT"
    if ! mountpoint -q "$LUKS_MOUNT"; then
        mount "/dev/mapper/${LUKS_NAME}" "$LUKS_MOUNT"
    fi

    # crypttab: auto-open at boot via Clevis/Tang (_netdev = wait for network)
    local uuid
    uuid=$(blkid -s UUID -o value "$LUKS_DEVICE")
    if ! grep -q "$LUKS_NAME" /etc/crypttab 2>/dev/null; then
        echo "${LUKS_NAME}  UUID=${uuid}  -  luks,_netdev,nofail,x-systemd.device-timeout=90s" \
            >> /etc/crypttab
        info "Added to /etc/crypttab"
    fi

    # fstab
    if ! grep -q "$LUKS_MOUNT" /etc/fstab 2>/dev/null; then
        echo "/dev/mapper/${LUKS_NAME}  ${LUKS_MOUNT}  ext4  defaults,_netdev  0  2" \
            >> /etc/fstab
        info "Added to /etc/fstab"
    fi

    # Regenerate initramfs so Clevis hook is included at early-boot
    update-initramfs -u
    info "initramfs updated with Clevis hook"
}

setup_user_and_dirs() {
    info "Creating spire user and directories"
    id -u "$SPIRE_USER" &>/dev/null || useradd \
        --system --no-create-home \
        --home-dir "$SPIRE_DATA_DIR" \
        --shell /usr/sbin/nologin \
        "$SPIRE_USER"

    mkdir -p \
        "$SPIRE_CONF_DIR" \
        "$SPIRE_DATA_DIR" \
        "$LUKS_MOUNT" \
        "$LOG_DIR"

    chown -R "$SPIRE_USER:$SPIRE_USER" \
        "$SPIRE_CONF_DIR" "$SPIRE_DATA_DIR" "$LUKS_MOUNT" "$LOG_DIR"
    chmod 700 "$LUKS_MOUNT"
}

generate_spire_intermediate_csr() {
    info "Generating ECDSA P-256 SPIRE intermediate CA key and CSR"
    local key_file="$SPIRE_CONF_DIR/intermediate_ca.key"
    local csr_file="$SPIRE_CONF_DIR/intermediate_ca.csr"

    if [[ -f "$key_file" ]]; then
        info "Key already exists; skipping"
    else
        openssl ecparam -genkey -name prime256v1 -noout \
            | openssl pkcs8 -topk8 -nocrypt -out "$key_file"
        chmod 600 "$key_file"
        chown "$SPIRE_USER:$SPIRE_USER" "$key_file"
    fi

    openssl req -new \
        -key "$key_file" \
        -out "$csr_file" \
        -subj "/CN=WOL SPIRE Intermediate CA/O=WOL Infrastructure"
    chown "$SPIRE_USER:$SPIRE_USER" "$csr_file"
    info "CSR: $csr_file"
}

# ---------------------------------------------------------------------------
# Disable IPv6 (prevent egress bypass of IPv4 NAT/firewall)
# ---------------------------------------------------------------------------

disable_ipv6() {
    info "Disabling IPv6"
    cat > /etc/sysctl.d/99-disable-ipv6.conf <<SYSCTL
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
SYSCTL
    sysctl -p /etc/sysctl.d/99-disable-ipv6.conf
}

# ---------------------------------------------------------------------------
# Default route via gateway (internet access for apt, certbot, etc.)
# ---------------------------------------------------------------------------

configure_gateway_route() {
    configure_ecmp_route
}

# ---------------------------------------------------------------------------
# DNS and NTP client (use both gateways)
# ---------------------------------------------------------------------------

configure_dns_ntp() {
    configure_dns
    configure_ntp
}

configure_firewall() {
    info "Configuring firewall (iptables)"
    iptables -F INPUT 2>/dev/null || true
    iptables -P INPUT DROP
    iptables -P OUTPUT ACCEPT
    iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    iptables -A INPUT -i lo -j ACCEPT
    iptables -A INPUT -s 10.0.0.0/24 -p tcp --dport 22 -j ACCEPT
    iptables -A INPUT -s 10.0.1.0/24 -p tcp --dport 22 -j ACCEPT
    # SPIRE Agent gRPC -- all hosts on the internal network
    iptables -A INPUT -s 10.0.0.0/24 -p tcp --dport 8081 -j ACCEPT
    iptables -A INPUT -s 10.0.1.0/24 -p tcp --dport 8081 -j ACCEPT
    # Health check -- internal network only
    iptables -A INPUT -s 10.0.0.0/24 -p tcp --dport 8080 -j ACCEPT
    iptables -A INPUT -s 10.0.1.0/24 -p tcp --dport 8080 -j ACCEPT
    # Persist rules
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4
    info "Firewall enabled (iptables)"
}

print_instructions() {
    local csr_file="$SPIRE_CONF_DIR/intermediate_ca.csr"
    cat <<EOF

================================================================
Setup complete. CSR generated at $csr_file.
The orchestrator (pve-deploy.sh) will automatically:
  1. Collect this CSR via pve-root-ca.sh
  2. Sign it with the offline root CA
  3. Distribute the signed cert back to this host
  4. Run 07-complete-spire-server.sh
================================================================
CSR collection and signing is automated by pve-root-ca.sh via the orchestrator.

3. Confirm the signed certificate has been placed on this host:
     $SPIRE_CONF_DIR/intermediate_ca.crt
     $SPIRE_CONF_DIR/root_ca.crt

4. Then run: SPIRE_DB_PASSWORD=<password> ./07-complete-spire-server.sh
   (Password from spire-db:/etc/wol-db-secrets/spire_password)
================================================================
EOF
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

main
