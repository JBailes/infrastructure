#!/usr/bin/env bash
# 08-complete-provisioning.sh -- Verify Provisioning CA cert after it is placed (10.0.0.205)
#
# Runs on: provisioning (10.0.0.205), Debian 13 LXC
# Run order: Step 07 (after root CA signing completes)
#
# Prerequisites:
#   - 05-setup-provisioning-host.sh has already run (phase 1)
#   - Signed Provisioning CA cert placed at /etc/wol-provisioning/ca.crt
#   - Root CA cert placed at /etc/wol-provisioning/root_ca.crt

set -euo pipefail

# Boot-time secret scrub: remove leftover .env.bootstrap from prior failed runs
rm -f /root/.env.bootstrap

PROV_DIR="/etc/wol-provisioning"

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

[[ $EUID -eq 0 ]] || err "Run as root"

check_cert_present() {
    [[ -f "$PROV_DIR/ca.crt" ]] \
        || err "Missing $PROV_DIR/ca.crt: place it before running this script"
    [[ -f "$PROV_DIR/root_ca.crt" ]] \
        || err "Missing $PROV_DIR/root_ca.crt"
    openssl verify -CAfile "$PROV_DIR/root_ca.crt" "$PROV_DIR/ca.crt" \
        || err "Provisioning CA cert does not verify against root CA"
    local fingerprint
    fingerprint=$(openssl x509 -in "$PROV_DIR/ca.crt" -noout -fingerprint -sha256)
    info "Provisioning CA cert verified: $fingerprint"
}

print_done() {
    cat <<'EOF'

================================================================
Provisioning CA is ready.

Provisioning CA cert distribution is handled by pve-root-ca.sh.
The provisioning host is taken offline automatically.
================================================================
EOF
}

check_cert_present
print_done
