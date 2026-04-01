#!/usr/bin/env bash
# 07-complete-spire-server.sh -- Finalize SPIRE Server after signed cert is placed (10.0.0.204)
#
# Runs on: spire-server (10.0.0.204), Debian 13 VM
# Run order: Step 06 (after root CA signing completes)
#
# Prerequisites:
#   - 04-setup-spire-server.sh has already run (phase 1)
#   - Signed SPIRE intermediate cert placed at /etc/spire/server/intermediate_ca.crt
#   - Root CA cert placed at /etc/spire/server/root_ca.crt
#   - SPIRE_DB_PASSWORD set in environment (from db:/etc/wol-db-secrets/spire_password)

set -euo pipefail

# Boot-time secret scrub: remove leftover .env.bootstrap from prior failed runs
rm -f /root/.env.bootstrap

SPIRE_USER="spire"
SPIRE_IP="10.0.0.204"
DB_IP="10.0.0.202"
LUKS_NAME="spire-keys"
LUKS_MOUNT="/var/lib/spire/keys"
SPIRE_CONF_DIR="/etc/spire/server"
SPIRE_DATA_DIR="/var/lib/spire/server"
SPIRE_BIN_DIR="/usr/local/bin"
LOG_DIR="/var/log/spire"

: "${SPIRE_DB_PASSWORD:?Set SPIRE_DB_PASSWORD environment variable}"

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

[[ $EUID -eq 0 ]] || err "Run as root"

check_certs_present() {
    [[ -f "$SPIRE_CONF_DIR/intermediate_ca.crt" ]] \
        || err "Missing $SPIRE_CONF_DIR/intermediate_ca.crt: place it before running this script"
    [[ -f "$SPIRE_CONF_DIR/root_ca.crt" ]] \
        || err "Missing $SPIRE_CONF_DIR/root_ca.crt"
    openssl verify -CAfile "$SPIRE_CONF_DIR/root_ca.crt" \
        "$SPIRE_CONF_DIR/intermediate_ca.crt" \
        || err "Intermediate cert does not verify against root CA"
    info "Cert chain verified"
}

write_spire_config() {
    info "Writing spire-server.conf"
    # Write config directly via heredoc: bash substitutes variables safely without
    # sed delimiter issues (passwords containing /, &, or \ are handled correctly).
    cat > "$SPIRE_CONF_DIR/server.conf" <<CONF
server {
    bind_address = "0.0.0.0"
    bind_port    = "8081"
    socket_path  = "/var/run/spire/server/private/api.sock"
    trust_domain = "wol"
    data_dir     = "$SPIRE_DATA_DIR"
    log_level    = "INFO"
    log_file     = "$LOG_DIR/server.log"
    ca_ttl                = "168h"
    default_x509_svid_ttl = "1h"
    default_jwt_svid_ttl  = "5m"
    ca_subject {
        country      = ["WOL"]
        organization = ["WOL Infrastructure"]
        common_name  = ""
    }
}
plugins {
    DataStore "sql" {
        plugin_data {
            database_type     = "postgres"
            connection_string = "host=${DB_IP} port=5432 dbname=spire user=spire sslmode=require password=${SPIRE_DB_PASSWORD}"
        }
    }
    KeyManager "disk" {
        plugin_data { keys_path = "${LUKS_MOUNT}/server_keys.json" }
    }
    NodeAttestor "join_token" { plugin_data {} }
    UpstreamAuthority "disk" {
        plugin_data {
            cert_file_path   = "${SPIRE_CONF_DIR}/intermediate_ca.crt"
            key_file_path    = "${SPIRE_CONF_DIR}/intermediate_ca.key"
            bundle_file_path = "${SPIRE_CONF_DIR}/root_ca.crt"
        }
    }
}
health_checks {
    listener_enabled = true
    bind_address = "0.0.0.0"
    bind_port    = "8080"
    live_path    = "/live"
    ready_path   = "/ready"
}
CONF
    chown "$SPIRE_USER:$SPIRE_USER" "$SPIRE_CONF_DIR/server.conf"
    chmod 640 "$SPIRE_CONF_DIR/server.conf"
}

write_systemd_unit() {
    info "Writing systemd unit for SPIRE Server"
    cat > /etc/systemd/system/spire-server.service <<EOF
[Unit]
Description=SPIRE Server
After=network-online.target
Wants=network-online.target
RequiresMountsFor=${LUKS_MOUNT}

[Service]
Type=simple
User=${SPIRE_USER}
Group=${SPIRE_USER}
ExecStart=${SPIRE_BIN_DIR}/spire-server run -config ${SPIRE_CONF_DIR}/server.conf
Restart=always
RestartSec=5
LimitNOFILE=65536
LimitCORE=0
NoNewPrivileges=true
PrivateTmp=true
StandardOutput=append:${LOG_DIR}/server.log
StandardError=append:${LOG_DIR}/server.log

[Install]
WantedBy=multi-user.target
EOF
}

wait_for_spire() {
    info "Waiting for SPIRE Server health check..."
    local i=0
    until curl -sf "http://localhost:8080/live" &>/dev/null; do
        sleep 2
        (( i++ )) && (( i >= 30 )) && err "SPIRE Server did not become healthy in 60s"
    done
    info "SPIRE Server healthy"
}

print_done() {
    cat <<'EOF'

================================================================
SPIRE Server is running.

Next: register node entries and generate join tokens for each host.
Run 12-register-workload-entries.sh after all SPIRE Agents are up.

To generate a join token for a new host (run on spire-server):
  spire-server token generate \
      -spiffeID spiffe://wol/node/<hostname> \
      -ttl 300
Join tokens are generated and distributed automatically by pve-deploy.sh.
================================================================
EOF
}

check_certs_present
write_spire_config
write_systemd_unit

# Ensure log directory and file are owned by spire user.
# systemd's StandardOutput=append: creates files as root, so we must
# pre-create the log file with the correct ownership before starting.
mkdir -p "$LOG_DIR"
touch "$LOG_DIR/server.log"
chown -R "$SPIRE_USER:$SPIRE_USER" "$LOG_DIR"

# Socket directory (outside /tmp so the CLI can reach it with PrivateTmp=true)
mkdir -p /var/run/spire/server/private
chown -R "$SPIRE_USER:$SPIRE_USER" /var/run/spire

systemctl daemon-reload
systemctl enable --now spire-server
wait_for_spire
info "SPIRE Server is running"
print_done
