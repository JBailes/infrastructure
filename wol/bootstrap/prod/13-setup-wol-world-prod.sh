#!/usr/bin/env bash
# 15-setup-wol-world-prod.sh -- Prepare wol-world-prod host environment
#
# Runs on: wol-world-prod (10.0.0.211) -- Debian 13 LXC (privileged)
# Run order: Step 12 (after SPIRE Agent and wol-world-db-prod are running)

set -euo pipefail
_LIB="$(dirname "$0")/../lib/common.sh"; [[ -f "$_LIB" ]] || _LIB="/root/lib/common.sh"; source "$_LIB"
scrub_bootstrap_secrets

WOL_USER="wol-world"
WOL_UID="1004"
WOL_GID="1004"
WOL_HOME="/var/lib/wol-world"
WOL_LIB="/usr/lib/wol-world"
WOL_ETC="/etc/wol-world"
WOL_LOG="/var/log/wol-world"
WOL_BIN="$WOL_LIB/Wol.World"
SPIRE_SOCKET="/var/run/spire/agent.sock"
API_PORT="8443"
DB_HOST="10.0.0.213"
DB_NAME="wol_world"
DB_USER="wol_world"
DB_CERT_CN="wol_world"

[[ $EUID -eq 0 ]] || err "Run as root"

install_packages() {
    info "Installing packages"
    apt-get update -qq
    apt-get install -y --no-install-recommends \
        curl ca-certificates iptables chrony gnupg python3 jq
    install_dotnet_runtime
}

setup_user() {
    create_service_user "$WOL_USER" "$WOL_UID" "$WOL_GID" "$WOL_HOME"
    add_to_spire_group "$WOL_USER"
}

setup_directories() {
    info "Creating directory structure"
    mkdir -p "$WOL_LIB" "$WOL_HOME" "$WOL_ETC/certs" "$WOL_LOG"
    chown -R "$WOL_USER:$WOL_USER" "$WOL_LIB" "$WOL_HOME" "$WOL_LOG"
    chown root:"$WOL_USER" "$WOL_ETC" "$WOL_ETC/certs"
    chmod 750 "$WOL_ETC" "$WOL_ETC/certs"
}

setup_db_cert() {
    if [[ -f "$WOL_ETC/certs/db-client.crt" ]]; then
        info "DB client cert already exists, skipping enrollment"
        return
    fi
    enroll_cert_from_ca "$DB_CERT_CN" "$WOL_ETC/certs/db-client.crt" "$WOL_ETC/certs/db-client.key" "db-client"
    chown "root:$WOL_USER" "$WOL_ETC/certs/db-client.crt" "$WOL_ETC/certs/db-client.key"
    chmod 640 "$WOL_ETC/certs/db-client.crt"
    chmod 600 "$WOL_ETC/certs/db-client.key"

    copy_root_ca "$WOL_ETC/certs"
}

write_cert_reload_script() {
    info "Writing verify-then-reload wrapper for cfssl cert renewal"
    cat > "/usr/local/bin/$WOL_USER-cert-reload" <<RELOAD
#!/usr/bin/env bash
set -euo pipefail
CERT="$WOL_ETC/certs/db-client.crt"
openssl x509 -in "\$CERT" -noout -subject -dates || { echo "ERROR: cert inspection failed" >&2; exit 1; }
systemctl reload $WOL_USER 2>/dev/null || systemctl restart $WOL_USER
for i in \$(seq 1 30); do
    if curl -sf -k https://127.0.0.1:$API_PORT/health &>/dev/null; then echo "Cert reloaded and service healthy"; exit 0; fi
    sleep 1
done
echo "ERROR: $WOL_USER health check failed after cert reload" >&2; exit 1
RELOAD
    chmod 755 "/usr/local/bin/$WOL_USER-cert-reload"
}

write_env_file() {
    local env_file="$WOL_ETC/$WOL_USER.env"
    [[ -f "$env_file" ]] && { info "Env file already exists; skipping"; return; }
    cat > "$env_file" <<EOF
SPIFFE_ENDPOINT_SOCKET=unix://$SPIRE_SOCKET
SPIFFE_TRUST_DOMAIN=spiffe://wol
DATABASE_URL=postgres://$DB_USER@$DB_HOST:5432/$DB_NAME?sslmode=verify-full&sslrootcert=$WOL_ETC/certs/root_ca.crt&sslcert=$WOL_ETC/certs/db-client.crt&sslkey=$WOL_ETC/certs/db-client.key
RATE_LIMIT_PER_CALLER_RPM=120
MAX_CONCURRENT_SNAPSHOTS=3
SNAPSHOT_QUERY_TIMEOUT=60
EOF
    chown "root:$WOL_USER" "$env_file"; chmod 640 "$env_file"
    info "Env file written to $env_file"
}

write_systemd_unit() {
    cat > "/etc/systemd/system/$WOL_USER.service" <<EOF
[Unit]
Description=WOL World API (prod)
After=network-online.target spire-agent.service
Wants=network-online.target
Requires=spire-agent.service
[Service]
Type=exec
User=${WOL_USER}
Group=${WOL_USER}
EnvironmentFile=${WOL_ETC}/${WOL_USER}.env
WorkingDirectory=${WOL_LIB}
ExecStart=${WOL_BIN}
Restart=always
RestartSec=2
LimitNOFILE=65536
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=${WOL_HOME} ${WOL_LOG}
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${WOL_USER}
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$WOL_USER"
    info "Systemd unit written. Service will start once binary is deployed."
}

configure_firewall() {
    fw_reset
    fw_allow_ssh
    iptables -A INPUT -s "$PROD_NET" -p tcp --dport "$API_PORT" -j ACCEPT
    iptables -A INPUT -s "$TEST_NET" -p tcp --dport "$API_PORT" -j ACCEPT
    fw_enable
}

main() {
    disable_ipv6
    configure_network
    install_packages
    setup_user
    setup_directories
    write_cert_reload_script
    setup_db_cert
    write_env_file
    write_systemd_unit
    configure_firewall
    info "wol-world-prod host environment is ready."
}

main "$@"
