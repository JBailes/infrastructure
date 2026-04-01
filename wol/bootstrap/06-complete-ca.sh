#!/usr/bin/env bash
# 06-complete-ca.sh -- Finalize CA and start cfssl serve (10.0.0.203)
#
# Runs on: ca (10.0.0.203), Debian 13 LXC
# Run order: Step 05 (after root CA generation and intermediate signing)
#
# Prerequisites:
#   - 03-setup-ca.sh has already run (phase 1)
#   - Signed intermediate cert placed at /etc/ca/certs/intermediate.crt
#   - Root CA cert placed at /etc/ca/certs/root_ca.crt

set -euo pipefail

# Boot-time secret scrub: remove leftover .env.bootstrap from prior failed runs
rm -f /root/.env.bootstrap

CA_USER="ca"
CA_HOME="/var/lib/ca"
CA_CONFIG_DIR="/etc/ca"
CA_IP="10.0.0.203"
CA_DNS="ca"
CA_PORT="8443"
LOG_DIR="/var/log/ca"

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

[[ $EUID -eq 0 ]] || err "Run as root"

check_certs_present() {
    [[ -f "$CA_CONFIG_DIR/certs/intermediate.crt" ]] \
        || err "Missing $CA_CONFIG_DIR/certs/intermediate.crt: place it before running this script"
    [[ -f "$CA_CONFIG_DIR/certs/root_ca.crt" ]] \
        || err "Missing $CA_CONFIG_DIR/certs/root_ca.crt"
    openssl verify -CAfile "$CA_CONFIG_DIR/certs/root_ca.crt" \
        "$CA_CONFIG_DIR/certs/intermediate.crt" \
        || err "Intermediate cert does not verify against root CA"
    info "Cert chain verified"
}

write_cfssl_config() {
    info "Writing cfssl signing config"
    local config_file="$CA_CONFIG_DIR/config/signing.json"

    mkdir -p "$CA_CONFIG_DIR/config"
    cat > "$config_file" <<'EOF'
{
  "signing": {
    "default": {
      "expiry": "168h"
    },
    "profiles": {
      "client": {
        "usages": ["signing", "key encipherment", "client auth"],
        "expiry": "8760h"
      },
      "db-client": {
        "usages": ["signing", "key encipherment", "client auth"],
        "expiry": "168h"
      },
      "server": {
        "usages": ["signing", "key encipherment", "server auth"],
        "expiry": "8760h"
      }
    }
  }
}
EOF
    chown "$CA_USER:$CA_USER" "$config_file"
    chmod 640 "$config_file"
    info "signing.json written"
}

write_systemd_unit() {
    info "Writing systemd unit"

    # Pre-create the log file with correct ownership so cfssl can write to it
    mkdir -p "$LOG_DIR"
    touch "$LOG_DIR/cfssl.log"
    chown "$CA_USER:$CA_USER" "$LOG_DIR/cfssl.log"

    cat > /etc/systemd/system/cfssl-ca.service <<EOF
[Unit]
Description=cfssl CA signing server
After=network.target

[Service]
Type=simple
User=${CA_USER}
Group=${CA_USER}
ExecStart=/usr/bin/cfssl serve \\
    -address 0.0.0.0 -port ${CA_PORT} \\
    -ca ${CA_CONFIG_DIR}/certs/intermediate.crt \\
    -ca-key ${CA_HOME}/secrets/intermediate.key \\
    -config ${CA_CONFIG_DIR}/config/signing.json
Restart=always
RestartSec=5
LimitNOFILE=65536
LimitCORE=0
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=${LOG_DIR}
StandardOutput=append:${LOG_DIR}/cfssl.log
StandardError=append:${LOG_DIR}/cfssl.log

[Install]
WantedBy=multi-user.target
EOF
}

wait_for_cfssl() {
    info "Waiting for cfssl to start (up to 30s)"
    # Give systemd a moment to start the service
    sleep 3
    local elapsed=0
    while (( elapsed < 30 )); do
        local rc=0
        curl -4 -sf "http://127.0.0.1:$CA_PORT/api/v1/cfssl/health" > /dev/null 2>&1 || rc=$?
        if [[ $rc -eq 0 ]]; then
            info "cfssl is responding on :$CA_PORT"
            return
        fi
        sleep 1
        (( elapsed++ )) || true
    done
    info "ERROR: cfssl did not respond on :$CA_PORT after 30s (last curl exit: $rc)"
    systemctl status cfssl-ca --no-pager 2>&1 || true
    exit 1
}

print_done() {
    local fingerprint
    fingerprint=$(openssl x509 -fingerprint -sha256 -noout -in "$CA_CONFIG_DIR/certs/root_ca.crt")
    cat <<EOF

================================================================
cfssl-ca is running.
  Root CA fingerprint: $fingerprint
  cfssl address: http://$CA_IP:$CA_PORT

DB client cert enrollment is automated by service bootstrap scripts.
================================================================
EOF
}

check_certs_present
write_cfssl_config
write_systemd_unit
systemctl daemon-reload
systemctl enable --now cfssl-ca
wait_for_cfssl
print_done
