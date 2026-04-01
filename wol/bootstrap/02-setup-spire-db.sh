#!/usr/bin/env bash
# 02-setup-spire-db.sh -- Set up PostgreSQL 17 + Tang NBDE server on the spire-db LXC (10.0.0.202)
#
# Runs on: spire-db (10.0.0.202), Debian 13 LXC
# Run order: Step 01 (must be up before SPIRE Server first boot with NBDE)
#
# After this script completes:
#   - Tang is running on :7500 (needed for SPIRE Server LUKS auto-unlock)
#   - PostgreSQL is running with password auth for 'spire' user
#   - PostgreSQL has self-signed SSL cert (replaced by CA cert after CA is running)
#   - Record the Tang advertisement URL for Clevis binding (printed at end)

set -euo pipefail
_LIB="$(dirname "$0")/lib/common.sh"; [[ -f "$_LIB" ]] || _LIB="/root/lib/common.sh"; source "$_LIB" 2>/dev/null || true
scrub_bootstrap_secrets 2>/dev/null || rm -f /root/.env.bootstrap

PG_VERSION="17"
DB_HOST="10.0.0.202"
SPIRE_DB_NAME="spire"
SPIRE_DB_USER="spire"
TANG_PORT="7500"
SSL_DIR="/etc/postgresql/${PG_VERSION}/main/ssl"

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

[[ $EUID -eq 0 ]] || err "Run as root"

# ---------------------------------------------------------------------------
# Packages
# ---------------------------------------------------------------------------

install_packages() {
    info "Installing packages"
    apt-get update -qq
    apt-get install -y --no-install-recommends \
        curl gnupg ca-certificates lsb-release iptables openssl tang jose

    # PostgreSQL 17 via pgdg
    local codename
    codename=$(lsb_release -cs)
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
        | gpg --dearmor -o /usr/share/keyrings/postgresql.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/postgresql.gpg] \
https://apt.postgresql.org/pub/repos/apt ${codename}-pgdg main" \
        > /etc/apt/sources.list.d/pgdg.list
    apt-get update -qq
    apt-get install -y "postgresql-${PG_VERSION}"
}

# ---------------------------------------------------------------------------
# Tang NBDE server
# ---------------------------------------------------------------------------

configure_tang() {
    info "Configuring Tang NBDE server on port $TANG_PORT"

    mkdir -p /var/db/tang
    chown tang:tang /var/db/tang 2>/dev/null || true

    # Tang uses systemd socket activation. Override the default port (tcp/7500).
    mkdir -p /etc/systemd/system/tangd.socket.d
    cat > /etc/systemd/system/tangd.socket.d/override.conf <<EOF
[Socket]
ListenStream=
ListenStream=$TANG_PORT
EOF

    systemctl daemon-reload
    systemctl enable --now tangd.socket

    # Generate Tang advertisement keys if not already present
    if ! compgen -G "/var/db/tang/*.jwk" >/dev/null 2>&1; then
        # tangd-update location varies by arch/distro
        local tangd_update
        tangd_update=$(find /usr/lib -name tangd-update 2>/dev/null | head -1)
        if [[ -n "$tangd_update" ]]; then
            "$tangd_update" /var/db/tang || true
        else
            # Generate keys by restarting tangd (creates keys on first request)
            systemctl restart tangd.socket || true
        fi
    fi

    info "Tang running. Advertisement URL: http://$DB_HOST:$TANG_PORT"
}

# ---------------------------------------------------------------------------
# PostgreSQL SSL (self-signed, replaced by CA cert later)
# ---------------------------------------------------------------------------

configure_pg_ssl() {
    info "Generating self-signed PostgreSQL server SSL certificate"
    mkdir -p "$SSL_DIR"

    openssl req -new -x509 \
        -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
        -keyout "$SSL_DIR/server.key" \
        -out "$SSL_DIR/server.crt" \
        -days 365 \
        -nodes \
        -subj "/CN=spire-db/O=WOL Infrastructure" \
        -addext "subjectAltName=DNS:spire-db,IP:$DB_HOST"

    chmod 600 "$SSL_DIR/server.key"
    chown postgres:postgres "$SSL_DIR/server.key" "$SSL_DIR/server.crt"
}

# ---------------------------------------------------------------------------
# PostgreSQL configuration
# ---------------------------------------------------------------------------

configure_postgresql() {
    info "Configuring PostgreSQL"
    local pg_conf="/etc/postgresql/${PG_VERSION}/main/postgresql.conf"
    local pg_hba="/etc/postgresql/${PG_VERSION}/main/pg_hba.conf"

    # SSL settings in postgresql.conf
    sed -i "s|^#\?ssl = .*|ssl = on|" "$pg_conf"
    sed -i "s|^#\?ssl_cert_file = .*|ssl_cert_file = '${SSL_DIR}/server.crt'|" "$pg_conf"
    sed -i "s|^#\?ssl_key_file = .*|ssl_key_file = '${SSL_DIR}/server.key'|" "$pg_conf"

    # Listen on internal network
    sed -i "s|^#\?listen_addresses = .*|listen_addresses = '127.0.0.1,${DB_HOST}'|" "$pg_conf"

    # pg_hba.conf:
    # - spire user: password auth (no client cert; avoids SPIRE bootstrap circular dependency)
    # - local connections: trust for postgres superuser
    cat > "$pg_hba" <<EOF
# TYPE  DATABASE        USER            ADDRESS             METHOD

# Local admin
local   all             postgres                            peer
local   all             all                                 reject

# SPIRE datastore -- password auth (no SVID cert; avoids circular dependency)
hostssl ${SPIRE_DB_NAME}    ${SPIRE_DB_USER}    10.0.0.204/32     scram-sha-256

# Deny everything else
host    all             all             0.0.0.0/0           reject
EOF

    # ssl_ca_file for client cert verification (root_ca.crt, distributed in step 0)
    # Set after root_ca.crt is placed; appended here as a placeholder
    if [[ -f /etc/ssl/wol/root_ca.crt ]]; then
        sed -i "s|^#\?ssl_ca_file = .*|ssl_ca_file = '/etc/ssl/wol/root_ca.crt'|" "$pg_conf"
    else
        info "NOTE: /etc/ssl/wol/root_ca.crt not yet present."
        info "After distributing root_ca.crt, run:"
        info "  sed -i \"s|^#\\?ssl_ca_file = .*|ssl_ca_file = '/etc/ssl/wol/root_ca.crt'|\" $pg_conf"
        info "  systemctl restart postgresql"
    fi

    systemctl restart postgresql
}

# ---------------------------------------------------------------------------
# PostgreSQL databases and users
# ---------------------------------------------------------------------------

create_databases() {
    info "Creating databases and users"

    # Generate a strong random password for the spire user
    local spire_password
    spire_password=$(openssl rand -base64 32)

    su -c "psql -v ON_ERROR_STOP=1" postgres <<SQL
-- SPIRE datastore database
SELECT 'CREATE DATABASE ${SPIRE_DB_NAME} OWNER postgres'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${SPIRE_DB_NAME}')\gexec

DO \$\$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${SPIRE_DB_USER}') THEN
    CREATE USER ${SPIRE_DB_USER} WITH PASSWORD '${spire_password}';
  ELSE
    ALTER USER ${SPIRE_DB_USER} WITH PASSWORD '${spire_password}';
  END IF;
END \$\$;
GRANT CONNECT ON DATABASE ${SPIRE_DB_NAME} TO ${SPIRE_DB_USER};
\c ${SPIRE_DB_NAME}
GRANT ALL ON SCHEMA public TO ${SPIRE_DB_USER};
SQL

    # Write spire password to a local file on spire-db host for the SPIRE Server to retrieve
    # Password is read automatically by pve-deploy.sh for spire-server steps
    mkdir -p /etc/wol-db-secrets
    echo "$spire_password" > /etc/wol-db-secrets/spire_password
    chmod 600 /etc/wol-db-secrets/spire_password
    chown root:root /etc/wol-db-secrets/spire_password

    info "================================================================"
    info "SPIRE DB password written to /etc/wol-db-secrets/spire_password"
    info "Password is injected automatically by pve-deploy.sh for spire-server steps"
    info "================================================================"
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
# Firewall
# ---------------------------------------------------------------------------

configure_firewall() {
    info "Configuring firewall (iptables)"
    fw_reset
    fw_allow_ssh

    # PostgreSQL -- only from spire-server
    iptables -A INPUT -s 10.0.0.204 -p tcp --dport 5432 -j ACCEPT

    # Tang -- only from spire-server (LUKS unlock)
    iptables -A INPUT -s 10.0.0.204 -p tcp --dport "$TANG_PORT" -j ACCEPT

    # postgres_exporter metrics (Prometheus scrape from obs only)
    iptables -A INPUT -s 10.0.0.100 -p tcp --dport 9187 -j ACCEPT

    fw_enable
    info "Firewall enabled"
}

    # NOTE: PostgreSQL starts with a self-signed cert. CA-issued certs are
    # enrolled later by 06-complete-ca.sh (after the CA is running).

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    disable_ipv6
    configure_gateway_route
    configure_dns_ntp
    install_packages
    configure_tang
    configure_pg_ssl
    configure_postgresql
    create_databases
    configure_firewall
    install_postgres_exporter
    info ""
    info "spire-db setup complete."
    info "Tang advertisement URL: http://$DB_HOST:$TANG_PORT"
    info "Verify Tang is working: curl http://$DB_HOST:$TANG_PORT/adv"
}

main "$@"
