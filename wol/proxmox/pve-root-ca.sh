#!/usr/bin/env bash
# pve-root-ca.sh -- Automated offline root CA generation and intermediate signing
#
# Runs on: the Proxmox host
#
# Creates a temporary Debian 13 LXC, installs openssl, disconnects from
# network, generates the root CA, signs intermediate CSRs, copies certs
# out, and takes the container offline.
#
# Usage:
#   ./pve-root-ca.sh generate          # First-time: create CA and sign intermediates
#   ./pve-root-ca.sh sign              # Re-sign: bring container online briefly for
#                                      #   package updates, then offline to sign new CSRs
#   ./pve-root-ca.sh destroy           # Remove the CA container entirely
#
# The root CA key never leaves the container. Certs are copied out via pct pull.
# The container is offline (no network) whenever the key is accessible.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

CA_NAME="wol-root-ca"
CA_CTID=$(resolve_ctid "$CA_NAME" 2>/dev/null) || CA_CTID=""
CA_IP="10.0.0.99"
CA_DIR="/root/ca"
CA_CERT_NAME="WOL Root CA"
OUTPUT_DIR="$SCRIPT_DIR/ca-output"

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
warn() { echo "WARN: $*" >&2; }

[[ $EUID -eq 0 ]] || err "Run as root"

# ---------------------------------------------------------------------------
# Container lifecycle
# ---------------------------------------------------------------------------

create_ca_container() {
    if [[ -n "$CA_CTID" ]] && pct status "$CA_CTID" &>/dev/null; then
        info "CA container $CA_CTID already exists"
        return
    fi
    if [[ -z "$CA_CTID" ]]; then
        CA_CTID=$(next_free_ctid "${CTID_RANGE_START:-200}")
    fi
    info "Creating temporary CA container ($CA_NAME, CTID $CA_CTID)"
    pct create "$CA_CTID" "$TEMPLATE_LXC" \
        --hostname "$CA_NAME" \
        --ostype debian \
        --storage "$STORAGE" \
        --rootfs "${STORAGE}:2" \
        --memory 256 \
        --cores 1 \
        --net0 "name=eth0,bridge=${PROD_BRIDGE},ip=${CA_IP}/24,gw=${BOOTSTRAP_GW}" \
        --unprivileged 1 \
        --features nesting=1

    info "Starting CA container..."
    rm -f "/var/lib/lxc/${CA_CTID}/monitor-sock"
    pct start "$CA_CTID" &>/dev/null || true
    sleep 5
}

configure_ca_container() {
    info "Configuring CA container (IPv6 disable, proxy, locale)"

    # Disable IPv6 (prevents apt from trying unreachable AAAA addresses)
    pct exec "$CA_CTID" -- bash -c '
        echo "net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1" > /etc/sysctl.d/99-disable-ipv6.conf
        sysctl -p /etc/sysctl.d/99-disable-ipv6.conf 2>/dev/null || true
    '

    # Push apt proxy config (apt-cacher-ng, HTTP only, no CA cert needed)
    local tmp_proxy
    tmp_proxy=$(mktemp)
    echo 'Acquire::http::Proxy "http://10.0.0.115:3142";' > "$tmp_proxy"
    pct exec "$CA_CTID" -- mkdir -p /etc/apt/apt.conf.d
    pct push "$CA_CTID" "$tmp_proxy" "/etc/apt/apt.conf.d/01proxy" --perms 0644
    rm -f "$tmp_proxy"
    info "Apt proxy config pushed to CA container"

    # Generate locale
    pct exec "$CA_CTID" -- bash -c '
        sed -i "s/^# *en_US.UTF-8/en_US.UTF-8/" /etc/locale.gen 2>/dev/null
        locale-gen en_US.UTF-8 2>/dev/null
    ' 2>/dev/null || true
}

install_packages() {
    info "Installing packages (container is online)"
    pct exec "$CA_CTID" -- bash -c '
        set -euo pipefail
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y --no-install-recommends \
            curl ca-certificates openssl
    '
    info "Packages installed"
}

go_offline() {
    info "Disconnecting container from network (air-gap)"
    # Remove the network interface entirely (skip if already removed)
    if pct config "$CA_CTID" | grep -q "^net0:"; then
        pct set "$CA_CTID" --delete net0
    else
        info "net0 already removed, container is already offline"
    fi
    # Restart to apply (container loses all network)
    pct reboot "$CA_CTID" &>/dev/null || true
    sleep 3
    info "Container is offline. No network interfaces."
}

go_online() {
    info "Reconnecting container to network (temporary)"
    pct set "$CA_CTID" --net0 "name=eth0,bridge=${PROD_BRIDGE},ip=${CA_IP}/24,gw=${BOOTSTRAP_GW}"
    pct reboot "$CA_CTID" &>/dev/null || true
    sleep 5
    info "Container is online"
}

# ---------------------------------------------------------------------------
# Root CA generation
# ---------------------------------------------------------------------------

generate_root_ca() {
    info "Generating root CA inside offline container"

    # Verify container is offline
    local net_config
    net_config=$(pct config "$CA_CTID" | grep "^net" || true)
    if [[ -n "$net_config" ]]; then
        warn "Container still has network interfaces. Going offline first."
        go_offline
    fi

    pct exec "$CA_CTID" -- bash -c "
        mkdir -p $CA_DIR
        if [[ -f $CA_DIR/root_ca.crt ]]; then
            echo 'Root CA already exists at $CA_DIR/root_ca.crt, skipping generation'
            exit 0
        fi
        # pathlen:2 allows root -> intermediate -> SPIRE CA -> leaf SVIDs
        openssl req -new -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
            -keyout $CA_DIR/root_ca.key -out $CA_DIR/root_ca.crt \
            -days 3650 -nodes \
            -subj '/CN=WOL Root CA' \
            -addext 'basicConstraints=critical,CA:TRUE,pathlen:2' \
            -addext 'keyUsage=critical,keyCertSign,cRLSign'
        chmod 600 $CA_DIR/root_ca.key
        echo 'Root CA generated successfully'
        openssl x509 -in $CA_DIR/root_ca.crt -noout -subject -dates
    "

    info "Root CA generated inside container"
}

# ---------------------------------------------------------------------------
# Sign intermediate CSRs
# ---------------------------------------------------------------------------

sign_intermediates() {
    info "Signing intermediate CA CSRs"
    mkdir -p "$OUTPUT_DIR"

    # Copy CSRs into the container (collected from ca, SPIRE, provisioning hosts)
    local csr_dir="$OUTPUT_DIR/csrs"
    mkdir -p "$csr_dir"

    info "Collecting CSRs from infrastructure hosts"

    # Resolve CTIDs and IPs from inventory
    local ca_entry spire_entry prov_entry
    ca_entry=$(lookup_host "ca") || err "ca not found in inventory"
    spire_entry=$(lookup_host "spire-server") || err "spire-server not found in inventory"
    prov_entry=$(lookup_host "provisioning") || err "provisioning not found in inventory"

    parse_host "$ca_entry"
    local CA_HOST_CTID="$H_CTID"

    parse_host "$spire_entry"
    local SPIRE_VMID="$H_CTID" SPIRE_IP="$H_IP"

    parse_host "$prov_entry"
    local PROV_CTID="$H_CTID"

    # CA intermediate CSR
    if pct status "$CA_HOST_CTID" &>/dev/null; then
        pct pull "$CA_HOST_CTID" /etc/ca/csr/intermediate.csr "$csr_dir/ca.csr" 2>/dev/null \
            && info "Collected: ca.csr" \
            || warn "Could not collect CA CSR (script 03 may not have run yet)"
    else
        warn "CA container ($CA_HOST_CTID) not running, cannot collect CSR"
    fi

    # SPIRE intermediate CSR
    if qm status "$SPIRE_VMID" &>/dev/null; then
        scp -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
            "root@${SPIRE_IP}:/etc/spire/server/intermediate_ca.csr" \
            "$csr_dir/spire-intermediate.csr" 2>/dev/null \
            && info "Collected: spire-intermediate.csr" \
            || warn "Could not collect SPIRE CSR (script 04 may not have run yet, or SSH not reachable)"
    else
        warn "spire-server VM ($SPIRE_VMID) not running, cannot collect CSR"
    fi

    # vTPM Provisioning CA CSR
    if pct status "$PROV_CTID" &>/dev/null; then
        pct pull "$PROV_CTID" /etc/wol-provisioning/csr/provisioning_ca.csr "$csr_dir/vtpm-provisioning.csr" 2>/dev/null \
            && info "Collected: vtpm-provisioning.csr" \
            || warn "Could not collect provisioning CSR (script 05 may not have run yet)"
    else
        warn "provisioning container ($PROV_CTID) not running, cannot collect CSR"
    fi

    # Verify we have at least one CSR to sign
    local csr_count
    csr_count=$(find "$csr_dir" -name "*.csr" 2>/dev/null | wc -l)
    if [[ "$csr_count" -eq 0 ]]; then
        err "No CSRs collected. Ensure scripts 03, 04, 05 have run before signing."
    fi
    info "Collected $csr_count CSR(s)"

    # Push each CSR into the CA container and sign it
    for csr_file in "$csr_dir"/*.csr; do
        [[ -f "$csr_file" ]] || continue
        local basename
        basename=$(basename "$csr_file" .csr)
        local remote_csr="$CA_DIR/${basename}.csr"
        local remote_crt="$CA_DIR/${basename}.crt"

        # SPIRE intermediate needs pathlen:1 (it mints its own X509 CA below).
        # CA and provisioning intermediates use default pathlen:0.
        local pathlen=0
        if [[ "$basename" == *spire* ]]; then
            pathlen=1
        fi

        info "Signing: $basename (pathlen:$pathlen)"
        pct push "$CA_CTID" "$csr_file" "$remote_csr"

        pct exec "$CA_CTID" -- bash -c "
            openssl x509 -req -in '$remote_csr' \
                -CA '$CA_DIR/root_ca.crt' -CAkey '$CA_DIR/root_ca.key' -CAcreateserial \
                -days 365 -sha256 \
                -extfile <(printf 'basicConstraints=critical,CA:TRUE,pathlen:%d\nkeyUsage=critical,keyCertSign,cRLSign' $pathlen) \
                -out '$remote_crt'
            echo 'Signed: $basename'
            openssl x509 -in '$remote_crt' -noout -subject -dates
        "

        # Pull signed cert back to Proxmox host
        pct pull "$CA_CTID" "$remote_crt" "$OUTPUT_DIR/${basename}.crt"
        info "Signed cert saved to $OUTPUT_DIR/${basename}.crt"
    done

    # Always pull root CA cert out
    pct pull "$CA_CTID" "$CA_DIR/root_ca.crt" "$OUTPUT_DIR/root_ca.crt"
    info "Root CA cert saved to $OUTPUT_DIR/root_ca.crt"

    info "Distributing signed intermediate certs back to their hosts"

    # Resolve CTIDs/IPs from inventory (may already be set from collection phase)
    local dist_ca dist_spire dist_prov
    dist_ca=$(lookup_host "ca") || err "ca not found in inventory"
    dist_spire=$(lookup_host "spire-server") || err "spire-server not found in inventory"
    dist_prov=$(lookup_host "provisioning") || err "provisioning not found in inventory"

    # CA intermediate cert + root CA
    parse_host "$dist_ca"
    if [[ -f "$OUTPUT_DIR/ca.crt" ]] && pct status "$H_CTID" &>/dev/null; then
        pct push "$H_CTID" "$OUTPUT_DIR/ca.crt" /etc/ca/certs/intermediate.crt
        pct push "$H_CTID" "$OUTPUT_DIR/root_ca.crt" /etc/ca/certs/root_ca.crt
        info "Distributed: CA intermediate + root CA to ca ($H_CTID)"
    fi

    # SPIRE intermediate cert + root CA
    parse_host "$dist_spire"
    if [[ -f "$OUTPUT_DIR/spire-intermediate.crt" ]] && qm status "$H_CTID" &>/dev/null; then
        scp -o StrictHostKeyChecking=accept-new "$OUTPUT_DIR/spire-intermediate.crt" \
            "root@${H_IP}:/etc/spire/server/intermediate_ca.crt"
        scp -o StrictHostKeyChecking=accept-new "$OUTPUT_DIR/root_ca.crt" \
            "root@${H_IP}:/etc/spire/server/root_ca.crt"
        info "Distributed: SPIRE intermediate + root CA to spire-server ($H_CTID)"
    fi

    # Provisioning CA cert + root CA
    parse_host "$dist_prov"
    if [[ -f "$OUTPUT_DIR/vtpm-provisioning.crt" ]] && pct status "$H_CTID" &>/dev/null; then
        pct push "$H_CTID" "$OUTPUT_DIR/vtpm-provisioning.crt" /etc/wol-provisioning/ca.crt
        pct push "$H_CTID" "$OUTPUT_DIR/root_ca.crt" /etc/wol-provisioning/root_ca.crt
        info "Distributed: provisioning CA + root CA to provisioning ($H_CTID)"
    fi

    info "All signed certs distributed"
}

distribute_root_cert() {
    info "Distributing root CA cert to all hosts"
    [[ -f "$OUTPUT_DIR/root_ca.crt" ]] || err "Root CA cert not found at $OUTPUT_DIR/root_ca.crt"

    local all_hosts=("${HOSTS[@]}" "${EXTERNAL_HOSTS[@]+"${EXTERNAL_HOSTS[@]}"}")
    for entry in "${all_hosts[@]}"; do
        parse_host "$entry"
        # Skip the CA container itself
        [[ "$H_NAME" == "$CA_NAME" ]] && continue

        if [[ "$H_TYPE" == "lxc" ]]; then
            if pct status "$H_CTID" &>/dev/null; then
                pct exec "$H_CTID" -- mkdir -p /etc/ssl/wol
                pct push "$H_CTID" "$OUTPUT_DIR/root_ca.crt" "/etc/ssl/wol/root_ca.crt"
                info "Root CA cert pushed to $H_NAME"
            else
                warn "$H_NAME not running, skipping"
            fi
        elif [[ "$H_TYPE" == "vm" ]]; then
            ssh -o StrictHostKeyChecking=accept-new "root@${H_IP}" "mkdir -p /etc/ssl/wol" 2>/dev/null && \
                scp -o StrictHostKeyChecking=accept-new "$OUTPUT_DIR/root_ca.crt" "root@${H_IP}:/etc/ssl/wol/root_ca.crt" && \
                info "Root CA cert pushed to $H_NAME" || \
                warn "$H_NAME not reachable, skipping"
        fi
    done
}

take_offline() {
    info "Taking CA container offline"
    go_offline
    info "CA container is offline. Root CA key is safe."
    info "To sign new intermediates later: ./pve-root-ca.sh sign"
}

destroy_ca() {
    info "Destroying CA container"
    if pct status "$CA_CTID" &>/dev/null; then
        pct stop "$CA_CTID" &>/dev/null || true
        pct destroy "$CA_CTID" --purge
        info "CA container destroyed"
    else
        info "CA container does not exist"
    fi
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

cmd_generate() {
    create_ca_container
    configure_ca_container
    install_packages
    go_offline
    generate_root_ca
    sign_intermediates
    distribute_root_cert
    take_offline

    cat <<EOF

================================================================
Root CA generation complete.

The CA container ($CA_NAME, CTID $CA_CTID) is offline.
Root CA key is inside the container at $CA_DIR/root_ca.key
Signed certs are at $OUTPUT_DIR/

The container has NO network interfaces. The key cannot be
exfiltrated over the network.

To sign new intermediates later:
  ./pve-root-ca.sh sign

To destroy the CA container:
  ./pve-root-ca.sh destroy
================================================================
EOF
}

cmd_sign() {
    if ! pct status "$CA_CTID" &>/dev/null; then
        err "CA container does not exist. Run: ./pve-root-ca.sh generate"
    fi

    # Briefly go online for package updates
    go_online
    configure_ca_container
    install_packages
    go_offline

    # Sign new CSRs
    sign_intermediates
    distribute_root_cert

    info "Signing complete. Container is offline."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

case "${1:-}" in
    generate) cmd_generate ;;
    sign)     cmd_sign ;;
    destroy)  destroy_ca ;;
    *)
        echo "Usage: $0 {generate|sign|destroy}"
        echo ""
        echo "  generate  Create CA container, generate root CA, sign intermediates"
        echo "  sign      Re-sign new intermediate CSRs (updates packages first)"
        echo "  destroy   Remove the CA container entirely"
        exit 1
        ;;
esac
