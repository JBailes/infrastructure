#!/usr/bin/env bash
# 10-setup-wol-accounts.sh -- Prepare wol-accounts host environment (10.0.0.207)
#
# Runs on: wol-accounts (10.0.0.207), Debian 13 LXC (privileged)
# Run order: Step 09 (SPIRE Agent must already be running on this host)
#
# This script sets up the host environment for the wol-accounts C#/.NET service:
#   - Service user (UID 1002, GID 1002)
#   - .NET 9 ASP.NET Core runtime
#   - Directory structure for published .NET binary
#   - SPIRE unix:path selector points directly to published executable
#   - cfssl CA cert renewal for DB client cert (CN=wol)
#   - Systemd service unit (enabled, starts once binary is deployed)
#
# The SPIRE Agent (10-setup-spire-agent.sh) must be run on this host first.
# After this script: deploy the published .NET binary via pve-build-services.sh.

set -euo pipefail

_LIB="$(dirname "$0")/lib/common.sh"; [[ -f "$_LIB" ]] || _LIB="/root/lib/common.sh"; source "$_LIB" 2>/dev/null || true

WOL_USER="wol-accounts"
WOL_UID="1002"
WOL_GID="1002"
WOL_HOME="/var/lib/wol-accounts"
WOL_LIB="/usr/lib/wol-accounts"
WOL_ETC="/etc/wol-accounts"
WOL_LOG="/var/log/wol-accounts"
WOL_BIN="$WOL_LIB/Wol.Accounts"
SPIRE_GROUP="spire"
SPIRE_SOCKET="/var/run/spire/agent.sock"
CA_IP="10.0.0.203"
CA_PORT="8443"
API_PORT="8443"

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

[[ $EUID -eq 0 ]] || err "Run as root"

# Boot-time secret scrub: remove leftover .env.bootstrap from prior failed runs
rm -f /root/.env.bootstrap

# ---------------------------------------------------------------------------
# Packages
# ---------------------------------------------------------------------------

install_packages() {
    info "Installing packages"
    apt-get update -qq
    apt-get install -y --no-install-recommends \
        curl ca-certificates iptables chrony gnupg

    # .NET 9 ASP.NET Core runtime (for running published binaries)
    install_dotnet_runtime

    # python3 and jq for cfssl API JSON parsing (cert enrollment)
    apt-get install -y --no-install-recommends python3 jq 2>/dev/null || true
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

    # Add to spire group so it can access the SPIRE agent socket
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
    # Certs dir owned by root, readable by service user
    chown root:"$WOL_USER" "$WOL_ETC" "$WOL_ETC/certs"
    chmod 750 "$WOL_ETC"
    chmod 750 "$WOL_ETC/certs"
}

# ---------------------------------------------------------------------------
# DB client cert (CN=wol) via cfssl CA
# ---------------------------------------------------------------------------

setup_db_cert() {
    info "Enrolling DB client cert (CN=wol_accounts) from cfssl CA"

    if [[ -f "$WOL_ETC/certs/db-client.crt" ]]; then
        info "DB client cert already exists, skipping enrollment"
        return
    fi

    enroll_cert_from_ca "wol_accounts" "$WOL_ETC/certs/db-client.crt" "$WOL_ETC/certs/db-client.key" "db-client"
    chown "root:$WOL_USER" "$WOL_ETC/certs/db-client.crt" "$WOL_ETC/certs/db-client.key"
    chmod 640 "$WOL_ETC/certs/db-client.crt"
    chmod 600 "$WOL_ETC/certs/db-client.key"

    copy_root_ca "$WOL_ETC/certs"
}

write_cert_reload_script() {
    info "Writing verify-then-reload wrapper for cert renewal"
    cat > /usr/local/bin/wol-accounts-cert-reload <<SCRIPT
#!/usr/bin/env bash
# Verify-then-reload wrapper for cert renewal
# Called after the cron job renews the DB client cert
set -euo pipefail

CERT="$WOL_ETC/certs/db-client.crt"

# 1. Verify new cert is valid and not expired
openssl x509 -in "\$CERT" -noout -subject -dates || { echo "ERROR: cert inspection failed" >&2; exit 1; }

# Check notAfter is in the future
NOT_AFTER=\$(openssl x509 -in "\$CERT" -noout -enddate | cut -d= -f2)
if [[ -n "\$NOT_AFTER" ]]; then
    EXPIRY=\$(date -d "\$NOT_AFTER" +%s 2>/dev/null || echo 0)
    NOW=\$(date +%s)
    if [[ \$EXPIRY -le \$NOW ]]; then
        echo "ERROR: renewed cert is already expired (notAfter: \$NOT_AFTER)" >&2
        exit 1
    fi
    echo "Cert valid until \$NOT_AFTER"
fi

# 2. Reload service
systemctl reload wol-accounts 2>/dev/null || systemctl restart wol-accounts

# 3. Health check (poll for 30s)
for i in \$(seq 1 30); do
    if curl -sf -k https://127.0.0.1:$API_PORT/health &>/dev/null; then
        echo "Cert reloaded and service healthy"
        exit 0
    fi
    sleep 1
done
echo "ERROR: wol-accounts health check failed after cert reload" >&2
exit 1
SCRIPT
    chmod 755 /usr/local/bin/wol-accounts-cert-reload
}

# ---------------------------------------------------------------------------
# Environment file
# ---------------------------------------------------------------------------

write_env_file() {
    info "Writing environment file template"
    local env_file="$WOL_ETC/wol-accounts.env"

    if [[ -f "$env_file" ]]; then
        info "Env file already exists; skipping"
        return
    fi

    cat > "$env_file" <<EOF
# wol-accounts environment configuration
# Edit before starting the service.

# SPIRE Workload API socket
SPIFFE_ENDPOINT_SOCKET=unix://$SPIRE_SOCKET
SPIFFE_TRUST_DOMAIN=spiffe://wol

# PostgreSQL connection (DB client cert paths managed by cfssl CA cert renewal)
DATABASE_URL=postgres://wol_accounts@10.0.0.206:5432/wol_accounts?sslmode=verify-full&sslrootcert=$WOL_ETC/certs/root_ca.crt&sslcert=$WOL_ETC/certs/db-client.crt&sslkey=$WOL_ETC/certs/db-client.key

# Session configuration
SESSION_TTL_HOURS=2
SESSION_INACTIVITY_TIMEOUT_MINUTES=30

# Lockout policy
LOCKOUT_MAX_ATTEMPTS=5
LOCKOUT_DURATION_MINUTES=15

# BCrypt
BCRYPT_WORK_FACTOR=12
BCRYPT_MAX_CONCURRENT=8
BCRYPT_DUMMY_HASH=

# Rate limiting (per caller SPIFFE ID)
RATE_LIMIT_PER_CALLER_RPM=60
RATE_LIMIT_EXISTS_PER_CALLER_RPM=10
RATE_LIMIT_SESSIONS_PER_ACCOUNT_PER_HOUR=10

# Session cleanup
SESSION_CLEANUP_INTERVAL_MINUTES=60
EOF

    chown "root:$WOL_USER" "$env_file"
    chmod 640 "$env_file"
    info "Env file written to $env_file (review before starting service)"
}

# ---------------------------------------------------------------------------
# Systemd unit
# ---------------------------------------------------------------------------

write_systemd_unit() {
    info "Writing wol-accounts systemd unit"
    cat > /etc/systemd/system/wol-accounts.service <<EOF
[Unit]
Description=WOL Accounts API
After=network-online.target spire-agent.service
Wants=network-online.target
Requires=spire-agent.service

[Service]
Type=exec
User=${WOL_USER}
Group=${WOL_USER}
EnvironmentFile=${WOL_ETC}/wol-accounts.env
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
SyslogIdentifier=wol-accounts

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable wol-accounts
    info "Systemd unit written. Service will start once binary is deployed."
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
# Default route via gateway (internet access for apt, etc.)
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

# ---------------------------------------------------------------------------
# Firewall
# ---------------------------------------------------------------------------

configure_firewall() {
    info "Configuring firewall (iptables)"
    fw_reset
    fw_allow_ssh
    # Accounts API (mTLS on 8443) from private network
    iptables -A INPUT -s 10.0.0.0/24 -p tcp --dport "$API_PORT" -j ACCEPT
    iptables -A INPUT -s 10.0.1.0/24 -p tcp --dport "$API_PORT" -j ACCEPT
    # Prometheus metrics scrape from obs
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
wol-accounts host environment is ready.

.NET binary path: $WOL_BIN
  (SPIRE unix:path selector target for workload attestation)
SPIRE socket:     $SPIRE_SOCKET
Env file:         $WOL_ETC/wol-accounts.env  (edit before starting)
Log:              journalctl -u wol-accounts

Deploy the published binary via pve-build-services.sh.
Database migrations are handled separately.
SPIRE workload registration is automated by step 12.
================================================================
EOF
}

main "$@"
