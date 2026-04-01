#!/usr/bin/env bash
# 12-setup-wol-world-db.sh -- Set up PostgreSQL for wol-world on dedicated DB host
#
# Runs on: wol-world-db-{prod,test} -- Debian 13 LXC
# Run order: After CA is running (for root_ca.crt distribution)
#
# This script sets up a dedicated PostgreSQL instance for the wol-world service:
#   - PostgreSQL 17 via pgdg
#   - Self-signed SSL cert (replaced by CA cert later)
#   - wol_world database
#   - wol_world user (runtime, cert auth)
#   - wol_world_migrate user (DDL, cert auth)
#   - pg_hba with client cert auth from wol-world API host (10.0.0.211)
#   - Firewall allowing only wol-world API host and SSH

set -euo pipefail

_LIB="$(dirname "$0")/lib/common.sh"; [[ -f "$_LIB" ]] || _LIB="/root/lib/common.sh"; source "$_LIB" 2>/dev/null || true

# Boot-time secret scrub: remove leftover .env.bootstrap from prior failed runs
rm -f /root/.env.bootstrap

PG_VERSION="17"
DB_HOST="${DB_HOST:?Set DB_HOST (e.g. 10.0.0.213 for prod, 10.0.0.218 for test)}"
DB_NAME="wol_world"
DB_USER="wol_world"
MIGRATE_USER="wol_world_migrate"
API_HOST="${API_HOST:?Set API_HOST (e.g. 10.0.0.211 for prod, 10.0.0.216 for test)}"
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
        curl gnupg ca-certificates lsb-release iptables openssl

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
        -subj "/CN=wol-world-db/O=WOL Infrastructure" \
        -addext "subjectAltName=DNS:wol-world-db,IP:$DB_HOST"

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
    # - wol_world/wol_world_migrate: cert auth (cfssl client certs, CN=username)
    # - local connections: peer for postgres superuser
    cat > "$pg_hba" <<EOF
# TYPE  DATABASE        USER                    ADDRESS             METHOD

# Local admin
local   all             postgres                                    peer
local   all             all                                         reject

# wol-world ($API_HOST) -- client cert auth (CA cert, CN=$DB_USER or CN=$MIGRATE_USER)
hostssl ${DB_NAME}      ${DB_USER}              ${API_HOST}/32      cert clientcert=verify-full
hostssl ${DB_NAME}      ${MIGRATE_USER}         ${API_HOST}/32      cert clientcert=verify-full

# Deny everything else
host    all             all                     0.0.0.0/0           reject
EOF

    # ssl_ca_file for client cert verification
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
# Database and users
# ---------------------------------------------------------------------------

create_database() {
    info "Creating $DB_NAME database and users"

    su -c "psql -v ON_ERROR_STOP=1" postgres <<SQL
SELECT 'CREATE DATABASE ${DB_NAME} OWNER postgres'
    WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${DB_NAME}')\gexec

-- Runtime user (SELECT/INSERT/UPDATE/DELETE only)
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${DB_USER}') THEN
        CREATE USER ${DB_USER};
    END IF;
END
\$\$;
GRANT CONNECT ON DATABASE ${DB_NAME} TO ${DB_USER};

-- Migration user (DDL + GRANT; used only during deployment)
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${MIGRATE_USER}') THEN
        CREATE USER ${MIGRATE_USER};
    END IF;
END
\$\$;
GRANT CONNECT ON DATABASE ${DB_NAME} TO ${MIGRATE_USER};
\c ${DB_NAME}
GRANT ALL ON SCHEMA public TO ${MIGRATE_USER};
SQL

    info "Database $DB_NAME created with users $DB_USER and $MIGRATE_USER"
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

# ---------------------------------------------------------------------------
# Firewall
# ---------------------------------------------------------------------------

configure_firewall() {
    info "Configuring firewall (iptables)"
    iptables -F INPUT 2>/dev/null || true
    iptables -P INPUT DROP
    iptables -P OUTPUT ACCEPT
    iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    iptables -A INPUT -i lo -j ACCEPT

    # SSH (management)
    iptables -A INPUT -s 10.0.0.0/24 -p tcp --dport 22 -j ACCEPT
    iptables -A INPUT -s 10.0.1.0/24 -p tcp --dport 22 -j ACCEPT

    # PostgreSQL -- only from wol-world API host
    iptables -A INPUT -s "$API_HOST" -p tcp --dport 5432 -j ACCEPT

    # Persist rules
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4
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
    configure_pg_ssl
    configure_postgresql
    create_database
    configure_firewall
    cat <<EOF

================================================================
wol-world-db setup complete ($DB_HOST).

Database:       $DB_NAME
Runtime user:   $DB_USER  (cert auth from $API_HOST)
Migration user: $MIGRATE_USER  (cert auth from $API_HOST)
================================================================
EOF
}

main "$@"
