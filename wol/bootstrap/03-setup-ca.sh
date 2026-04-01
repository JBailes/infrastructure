#!/usr/bin/env bash
# 03-setup-ca.sh -- Install cfssl and generate intermediate CSR (10.0.0.203)
#
# Runs on: ca (10.0.0.203), Debian 13 LXC
# Run order: Step 02 (after db is up)
#
# After this script completes:
#   CSR is collected automatically by pve-root-ca.sh
#   Signing is automated by pve-deploy.sh at step 07
#   - Then run 06-complete-ca.sh to finalize and start cfssl

set -euo pipefail

_LIB="$(dirname "$0")/lib/common.sh"; [[ -f "$_LIB" ]] || _LIB="/root/lib/common.sh"; source "$_LIB" 2>/dev/null || true

scrub_bootstrap_secrets

CA_IP="10.0.0.203"
CA_DNS="ca"
CA_PORT="8443"
CA_USER="ca"
CA_HOME="/var/lib/ca"
CA_CONFIG_DIR="/etc/ca"
LOG_DIR="/var/log/ca"

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

[[ $EUID -eq 0 ]] || err "Run as root"

# ---------------------------------------------------------------------------
# Phase 1: install, generate key and CSR
# ---------------------------------------------------------------------------

main() {
    disable_ipv6
    configure_gateway_route
    configure_dns_ntp
    install_packages
    setup_user_and_dirs
    generate_intermediate_csr
    configure_firewall
    print_summary
}

install_packages() {
    info "Installing packages"
    apt-get update -qq
    apt-get install -y --no-install-recommends \
        golang-cfssl openssl curl ca-certificates iptables jq chrony
}

setup_user_and_dirs() {
    info "Creating ca user and directories"
    id -u "$CA_USER" &>/dev/null || useradd \
        --system --no-create-home \
        --home-dir "$CA_HOME" \
        --shell /usr/sbin/nologin \
        "$CA_USER"

    mkdir -p \
        "$CA_CONFIG_DIR/certs" \
        "$CA_CONFIG_DIR/csr" \
        "$CA_CONFIG_DIR/config" \
        "$CA_CONFIG_DIR/templates" \
        "$CA_HOME/db" \
        "$CA_HOME/secrets" \
        "$LOG_DIR"

    chown -R "$CA_USER:$CA_USER" "$CA_CONFIG_DIR" "$CA_HOME" "$LOG_DIR"
    chmod 700 "$CA_HOME/secrets"
}

generate_intermediate_csr() {
    info "Generating ECDSA P-256 intermediate CA key and CSR"
    local key_file="$CA_HOME/secrets/intermediate.key"
    local csr_file="$CA_CONFIG_DIR/csr/intermediate.csr"

    if [[ -f "$key_file" ]]; then
        info "Key already exists at $key_file; skipping generation"
    else
        openssl ecparam -genkey -name prime256v1 -noout \
            | openssl pkcs8 -topk8 -nocrypt -out "$key_file"
        chmod 600 "$key_file"
        chown "$CA_USER:$CA_USER" "$key_file"
        info "Generated intermediate key: $key_file"
    fi

    openssl req -new \
        -key "$key_file" \
        -out "$csr_file" \
        -subj "/CN=WOL CA Intermediate/O=WOL Infrastructure"
    chown "$CA_USER:$CA_USER" "$csr_file"
    info "CSR written to: $csr_file"
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
    fw_reset
    fw_allow_ssh
    # cfssl API: all private-network hosts need cert enrollment (enroll-host-certs.sh)
    iptables -A INPUT -s 10.0.0.0/24 -p tcp --dport "$CA_PORT" -j ACCEPT
    iptables -A INPUT -s 10.0.1.0/24 -p tcp --dport "$CA_PORT" -j ACCEPT
    fw_enable
}

print_summary() {
    local csr_file="$CA_CONFIG_DIR/csr/intermediate.csr"
    cat <<EOF

================================================================
Setup complete. CSR generated at $csr_file.
The orchestrator (pve-deploy.sh) will automatically:
  1. Collect this CSR via pve-root-ca.sh
  2. Sign it with the offline root CA
  3. Distribute the signed cert back to this host
  4. Run 06-complete-ca.sh
================================================================
CSR collection and signing is automated by pve-root-ca.sh via the orchestrator.

3. Confirm the signed certificate has been placed on this host:
     $CA_CONFIG_DIR/certs/intermediate.crt
     $CA_CONFIG_DIR/certs/root_ca.crt

4. Then run: ./06-complete-ca.sh
================================================================
EOF
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

main
