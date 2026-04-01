#!/usr/bin/env bash
# 05-setup-provisioning-host.sh -- Install vTPM Provisioning CA and generate CSR (10.0.0.205)
#
# Runs on: provisioning (10.0.0.205), Debian 13 LXC
# Run order: Step 04 (after CA setup)
#
# This host holds the vTPM Provisioning CA key, used to sign DevID certs for Proxmox VM vTPMs.
# It is network-isolated during non-provisioning periods.
# The CA key MUST NOT reside on the spire-server host.
#
# After this script completes:
#   CSR is collected automatically by pve-root-ca.sh
#   Signing is automated by pve-deploy.sh at step 07
#   - Then run: ./08-complete-provisioning.sh

set -euo pipefail

_LIB="$(dirname "$0")/lib/common.sh"; [[ -f "$_LIB" ]] || _LIB="/root/lib/common.sh"; source "$_LIB" 2>/dev/null || true

# Boot-time secret scrub: remove leftover .env.bootstrap from prior failed runs
rm -f /root/.env.bootstrap

PROV_IP="10.0.0.205"
PROV_USER="wol-provisioning"
PROV_DIR="/etc/wol-provisioning"
PROV_HOME="/var/lib/wol-provisioning"

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

[[ $EUID -eq 0 ]] || err "Run as root"

# ---------------------------------------------------------------------------
# Phase 1: install, generate Provisioning CA key + CSR
# ---------------------------------------------------------------------------

main() {
    disable_ipv6
    configure_gateway_route
    configure_dns_ntp
    install_packages
    setup_user_and_dirs
    generate_provisioning_ca_csr
    write_devid_issuance_script
    configure_firewall
    print_instructions
}

install_packages() {
    info "Installing packages"
    apt-get update -qq
    apt-get install -y --no-install-recommends \
        curl openssl iptables tpm2-tools
}

setup_user_and_dirs() {
    info "Creating provisioning user and directories"
    id -u "$PROV_USER" &>/dev/null || useradd \
        --system --no-create-home \
        --home-dir "$PROV_HOME" \
        --shell /usr/sbin/nologin \
        "$PROV_USER"

    mkdir -p "$PROV_DIR/certs" "$PROV_DIR/csr" "$PROV_HOME/secrets" "$PROV_HOME/issued"
    chown -R "$PROV_USER:$PROV_USER" "$PROV_DIR" "$PROV_HOME"
    chmod 700 "$PROV_HOME/secrets"
}

generate_provisioning_ca_csr() {
    info "Generating vTPM Provisioning CA key and CSR"
    local key_file="$PROV_HOME/secrets/provisioning_ca.key"
    local csr_file="$PROV_DIR/csr/provisioning_ca.csr"

    if [[ -f "$key_file" ]]; then
        info "Key already exists; skipping"
    else
        openssl ecparam -genkey -name prime256v1 -noout \
            | openssl pkcs8 -topk8 -nocrypt -out "$key_file"
        chmod 600 "$key_file"
        chown "$PROV_USER:$PROV_USER" "$key_file"
    fi

    openssl req -new \
        -key "$key_file" \
        -out "$csr_file" \
        -subj "/CN=WOL vTPM Provisioning CA/O=WOL Infrastructure"
    chown "$PROV_USER:$PROV_USER" "$csr_file"
    info "CSR: $csr_file"
}

write_devid_issuance_script() {
    info "Writing DevID certificate issuance script"
    # This script is called during VM provisioning to issue a DevID cert to a VM's vTPM
    cat > /usr/local/bin/issue-devid-cert <<'ISSUE_SCRIPT'
#!/usr/bin/env bash
# issue-devid-cert -- Issue a DevID certificate for a VM's vTPM
#
# Usage: issue-devid-cert <vm-name> <csr-file>
# The signed DevID cert is printed to stdout and saved to /var/lib/wol-provisioning/issued/<vm-name>.crt

set -euo pipefail

# Boot-time secret scrub: remove leftover .env.bootstrap from prior failed runs
rm -f /root/.env.bootstrap

PROV_HOME="/var/lib/wol-provisioning"
PROV_DIR="/etc/wol-provisioning"

[[ $# -eq 2 ]] || { echo "Usage: $0 <vm-name> <csr-file>" >&2; exit 1; }
VM_NAME="$1"
CSR_FILE="$2"

[[ -f "$CSR_FILE" ]]            || { echo "CSR not found: $CSR_FILE" >&2; exit 1; }
[[ -f "$PROV_DIR/ca.crt" ]]     || { echo "Provisioning CA cert not found" >&2; exit 1; }
[[ -f "$PROV_HOME/secrets/provisioning_ca.key" ]] || { echo "Provisioning CA key not found" >&2; exit 1; }

OUT_CERT="$PROV_HOME/issued/${VM_NAME}.crt"
mkdir -p "$PROV_HOME/issued"

openssl x509 -req \
    -in "$CSR_FILE" \
    -CA "$PROV_DIR/ca.crt" \
    -CAkey "$PROV_HOME/secrets/provisioning_ca.key" \
    -CAcreateserial \
    -out "$OUT_CERT" \
    -days 3650 \
    -extensions devid_ext \
    -extfile <(cat <<EOF
[devid_ext]
basicConstraints = CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = 1.3.6.1.4.1.57264.1.1
subjectKeyIdentifier = hash
EOF
)

echo "DevID cert issued: $OUT_CERT"
cat "$OUT_CERT"
ISSUE_SCRIPT

    chmod 755 /usr/local/bin/issue-devid-cert
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
    info "Configuring firewall (very restrictive, provisioning host is isolated)"
    iptables -F INPUT 2>/dev/null || true
    iptables -P INPUT DROP
    iptables -P OUTPUT ACCEPT
    iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    iptables -A INPUT -i lo -j ACCEPT
    # SSH only from Proxmox management network (adjust to your Proxmox host IP)
    iptables -A INPUT -s 10.0.0.0/24 -p tcp --dport 22 -j ACCEPT
    iptables -A INPUT -s 10.0.1.0/24 -p tcp --dport 22 -j ACCEPT
    # DevID CSR submission: accept from Proxmox host running provisioning scripts
    # Adjust to your Proxmox management IP
    iptables -A INPUT -s 10.0.0.0/24 -p tcp --dport 9000 -j ACCEPT
    iptables -A INPUT -s 10.0.1.0/24 -p tcp --dport 9000 -j ACCEPT
    # Persist rules
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4
    info "Provisioning host firewall: SSH + CSR submission only"
}

print_instructions() {
    cat <<EOF

================================================================
Setup complete. CSR generated.
The orchestrator (pve-deploy.sh) will automatically:
  1. Collect this CSR via pve-root-ca.sh
  2. Sign it with the offline root CA
  3. Distribute the signed cert back to this host
  4. Run 08-complete-provisioning.sh
================================================================
CSR collection and signing is automated by pve-root-ca.sh via the orchestrator.

3. Confirm the signed certificate has been placed on this host:
     $PROV_DIR/ca.crt
     $PROV_DIR/root_ca.crt

4. Then run: ./08-complete-provisioning.sh
================================================================
EOF
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

main
