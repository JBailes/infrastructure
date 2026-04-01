#!/usr/bin/env bash
# 13-setup-wol-world.sh -- Prepare wol-world host environment
#
# Runs on: wol-world-{prod,test} -- Debian 13 LXC (privileged)
# Run order: Step 12 (after SPIRE Agent and wol-world-db are running)
#
# This script sets up the host environment for the wol-world C#/.NET service:
#   - Service user (UID 1004, GID 1004)
#   - .NET 9 runtime
#   - Directory structure for published .NET binary
#   - SPIRE unix:path selector points directly to published executable
#   - cfssl cert renewal for DB client cert (CN=wol_world)
#   - Systemd service unit (placeholder until service code is deployed)
#
# The SPIRE Agent must be running on this host first.
# After this script: deploy the published .NET binary and run `systemctl start wol-world`.

set -euo pipefail

_LIB="$(dirname "$0")/lib/common.sh"; [[ -f "$_LIB" ]] || _LIB="/root/lib/common.sh"; source "$_LIB" 2>/dev/null || true

WOL_USER="wol-world"
WOL_UID="1004"
WOL_GID="1004"
WOL_HOME="/var/lib/wol-world"
WOL_LIB="/usr/lib/wol-world"
WOL_ETC="/etc/wol-world"
WOL_LOG="/var/log/wol-world"
WOL_BIN="$WOL_LIB/Wol.World"
SPIRE_GROUP="spire"
SPIRE_SOCKET="/var/run/spire/agent.sock"
CA_IP="10.0.0.203"
CA_PORT="8443"
API_PORT="8443"
DB_HOST="${DB_HOST:?Set DB_HOST (e.g. 10.0.0.213 for prod, 10.0.0.218 for test)}"
DB_NAME="wol_world"
DB_USER="wol_world"
DB_CERT_CN="wol_world"

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

[[ $EUID -eq 0 ]] || err "Run as root"

rm -f /root/.env.bootstrap

# ---------------------------------------------------------------------------
# Packages
# ---------------------------------------------------------------------------

install_packages() {
    info "Installing packages"
    apt-get update -qq
    apt-get install -y --no-install-recommends \
        curl ca-certificates iptables chrony gnupg python3 jq

    # .NET 9 ASP.NET Core runtime (for running published binaries)
    install_dotnet_runtime
}

# ---------------------------------------------------------------------------
# Service user and group
# ---------------------------------------------------------------------------

setup_user() {
    info "Creating $WOL_USER user (UID $WOL_UID)"
    getent group "$WOL_GID" &>/dev/null || groupadd --gid "$WOL_GID" "$WOL_USER"
    id -u "$WOL_USER" &>/dev/null || useradd \
        --uid "$WOL_UID" \
        --gid "$WOL_GID" \
        --no-create-home \
        --home-dir "$WOL_HOME" \
        --shell /usr/sbin/nologin \
        "$WOL_USER"

    usermod -aG "$SPIRE_GROUP" "$WOL_USER"
    info "Added $WOL_USER to $SPIRE_GROUP group"
}

# ---------------------------------------------------------------------------
# Directory structure
# ---------------------------------------------------------------------------

setup_directories() {
    info "Creating directory structure"
    mkdir -p \
        "$WOL_LIB" \
        "$WOL_HOME" \
        "$WOL_ETC/certs" \
        "$WOL_LOG"

    chown -R "$WOL_USER:$WOL_USER" "$WOL_LIB" "$WOL_HOME" "$WOL_LOG"
    chown root:"$WOL_USER" "$WOL_ETC" "$WOL_ETC/certs"
    chmod 750 "$WOL_ETC"
    chmod 750 "$WOL_ETC/certs"
}

# ---------------------------------------------------------------------------
# DB client cert (CN=wol_world) via cfssl CA
# ---------------------------------------------------------------------------

setup_db_cert() {
    if [[ -f "$WOL_ETC/certs/db-client.crt" ]]; then
        info "DB client cert already exists, skipping enrollment"
        return
    fi

    declare -F enroll_cert_from_ca >/dev/null || err "Missing enroll_cert_from_ca (ensure lib/common.sh is sourced)"
    info "Enrolling DB client cert (CN=$DB_CERT_CN) from cfssl CA"
    enroll_cert_from_ca "$DB_CERT_CN" "$WOL_ETC/certs/db-client.crt" "$WOL_ETC/certs/db-client.key" "db-client"
    chown "root:$WOL_USER" "$WOL_ETC/certs/db-client.crt" "$WOL_ETC/certs/db-client.key"
    chmod 640 "$WOL_ETC/certs/db-client.crt"
    chmod 600 "$WOL_ETC/certs/db-client.key"
    copy_root_ca "$WOL_ETC/certs"
    info "DB client cert enrolled successfully"
}

write_cert_reload_script() {
    info "Writing verify-then-reload wrapper for cfssl cert renewal"
    cat > "/usr/local/bin/$WOL_USER-cert-reload" <<SCRIPT
#!/usr/bin/env bash
set -euo pipefail
CERT="$WOL_ETC/certs/db-client.crt"
openssl x509 -in "\$CERT" -noout -subject -dates || { echo "ERROR: cert inspection failed" >&2; exit 1; }
systemctl reload $WOL_USER 2>/dev/null || systemctl restart $WOL_USER
for i in \$(seq 1 30); do
    if curl -sf -k https://127.0.0.1:$API_PORT/health &>/dev/null; then
        echo "Cert reloaded and service healthy"
        exit 0
    fi
    sleep 1
done
echo "ERROR: $WOL_USER health check failed after cert reload" >&2
exit 1
SCRIPT
    chmod 755 "/usr/local/bin/$WOL_USER-cert-reload"
}

# ---------------------------------------------------------------------------
# Environment file
# ---------------------------------------------------------------------------

write_env_file() {
    info "Writing environment file template"
    local env_file="$WOL_ETC/$WOL_USER.env"

    if [[ -f "$env_file" ]]; then
        info "Env file already exists; skipping"
        return
    fi

    cat > "$env_file" <<EOF
# $WOL_USER environment configuration

# SPIRE Workload API socket
SPIFFE_ENDPOINT_SOCKET=unix://$SPIRE_SOCKET
SPIFFE_TRUST_DOMAIN=spiffe://wol

# PostgreSQL connection
DATABASE_URL=postgres://$DB_USER@$DB_HOST:5432/$DB_NAME?sslmode=verify-full&sslrootcert=$WOL_ETC/certs/root_ca.crt&sslcert=$WOL_ETC/certs/db-client.crt&sslkey=$WOL_ETC/certs/db-client.key

# Rate limiting (per caller SPIFFE ID)
RATE_LIMIT_PER_CALLER_RPM=120

# Bulk snapshot limits
MAX_CONCURRENT_SNAPSHOTS=3
SNAPSHOT_QUERY_TIMEOUT=60
EOF

    chown "root:$WOL_USER" "$env_file"
    chmod 640 "$env_file"
    info "Env file written to $env_file"
}

# ---------------------------------------------------------------------------
# Systemd unit
# ---------------------------------------------------------------------------

write_systemd_unit() {
    info "Writing $WOL_USER systemd unit"
    cat > "/etc/systemd/system/$WOL_USER.service" <<EOF
[Unit]
Description=WOL World API
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
LimitCORE=0
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
    info "Systemd unit written. Service will NOT start until .NET binary is deployed."
}

# ---------------------------------------------------------------------------
# Network and firewall
# ---------------------------------------------------------------------------

disable_ipv6() {
    info "Disabling IPv6"
    cat > /etc/sysctl.d/99-disable-ipv6.conf <<SYSCTL
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
SYSCTL
    sysctl -p /etc/sysctl.d/99-disable-ipv6.conf
}

configure_gateway_route() {
    configure_ecmp_route
}

configure_dns_ntp() {
    configure_dns
    configure_ntp
}

configure_firewall() {
    info "Configuring firewall (iptables)"
    fw_reset
    fw_allow_ssh
    iptables -A INPUT -s 10.0.0.0/24 -p tcp --dport "$API_PORT" -j ACCEPT
    iptables -A INPUT -s 10.0.1.0/24 -p tcp --dport "$API_PORT" -j ACCEPT
    fw_enable
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    disable_ipv6
    configure_gateway_route
    configure_dns_ntp
    install_packages
    setup_user
    setup_directories
    write_cert_reload_script
    setup_db_cert
    write_env_file
    write_systemd_unit
    configure_firewall

    cat <<EOF

================================================================
$WOL_USER host environment is ready.

.NET binary path: $WOL_BIN
SPIRE socket:     $SPIRE_SOCKET
Env file:         $WOL_ETC/$WOL_USER.env

Host environment ready. Service deployment and migrations
are handled separately. SPIRE registration is automated by step 12.
================================================================
EOF
}

main "$@"
