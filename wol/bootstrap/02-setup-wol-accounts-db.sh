#!/usr/bin/env bash
# 02-setup-wol-accounts-db.sh -- Set up PostgreSQL for wol-accounts (shared)
#
# Runs on: wol-accounts-db (10.0.0.206) -- Debian 13 LXC
# Run order: After CA is running (for root_ca.crt distribution)
#
# Sets up a dedicated PostgreSQL instance for the wol-accounts service:
#   - PostgreSQL 17 via pgdg
#   - Self-signed SSL cert (replaced by CA cert later)
#   - wol_accounts database
#   - wol_accounts user (runtime, cert auth)
#   - wol_accounts_migrate user (DDL, cert auth)
#   - pg_hba with client cert auth from wol-accounts (10.0.0.207)
#   - Firewall allowing only wol-accounts and SSH

set -euo pipefail
_LIB="$(dirname "$0")/lib/common.sh"; [[ -f "$_LIB" ]] || _LIB="/root/lib/common.sh"; source "$_LIB"
scrub_bootstrap_secrets

PG_VERSION="17"
DB_HOST="10.0.0.206"
DB_NAME="wol_accounts"
DB_USER="wol_accounts"
MIGRATE_USER="wol_accounts_migrate"
API_HOST="10.0.0.207"
SSL_DIR="/etc/postgresql/${PG_VERSION}/main/ssl"

[[ $EUID -eq 0 ]] || err "Run as root"

# ---------------------------------------------------------------------------
# Packages
# ---------------------------------------------------------------------------

install_packages() {
    info "Installing packages"
    apt-get update -qq
    apt-get install -y --no-install-recommends \
        curl gnupg ca-certificates lsb-release iptables openssl chrony

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
        -subj "/CN=wol-accounts-db/O=WOL Infrastructure" \
        -addext "subjectAltName=DNS:wol-accounts-db,IP:$DB_HOST"

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

    sed -i "s|^#\?ssl = .*|ssl = on|" "$pg_conf"
    sed -i "s|^#\?ssl_cert_file = .*|ssl_cert_file = '${SSL_DIR}/server.crt'|" "$pg_conf"
    sed -i "s|^#\?ssl_key_file = .*|ssl_key_file = '${SSL_DIR}/server.key'|" "$pg_conf"
    sed -i "s|^#\?listen_addresses = .*|listen_addresses = '127.0.0.1,${DB_HOST}'|" "$pg_conf"

    cat > "$pg_hba" <<EOF
# TYPE  DATABASE        USER                    ADDRESS             METHOD

# Local admin
local   all             postgres                                    peer
local   all             all                                         reject

# wol-accounts ($API_HOST) -- client cert auth
hostssl ${DB_NAME}      ${DB_USER}              ${API_HOST}/32      cert clientcert=verify-full
hostssl ${DB_NAME}      ${MIGRATE_USER}         ${API_HOST}/32      cert clientcert=verify-full

# Deny everything else
host    all             all                     0.0.0.0/0           reject
EOF

    if [[ -f /etc/ssl/wol/root_ca.crt ]]; then
        sed -i "s|^#\?ssl_ca_file = .*|ssl_ca_file = '/etc/ssl/wol/root_ca.crt'|" "$pg_conf"
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

DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${DB_USER}') THEN
        CREATE USER ${DB_USER};
    END IF;
END
\$\$;
GRANT CONNECT ON DATABASE ${DB_NAME} TO ${DB_USER};

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
# Firewall
# ---------------------------------------------------------------------------

configure_firewall() {
    fw_reset
    fw_allow_ssh
    iptables -A INPUT -s "$API_HOST" -p tcp --dport 5432 -j ACCEPT
    iptables -A INPUT -s 10.0.0.100 -p tcp --dport 9187 -j ACCEPT
    fw_enable
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    disable_ipv6
    configure_network
    install_packages
    configure_pg_ssl
    configure_postgresql
    create_database
    configure_firewall
    install_postgres_exporter

    cat <<EOF

================================================================
wol-accounts-db setup complete ($DB_HOST).

Database:       $DB_NAME
Runtime user:   $DB_USER  (cert auth from $API_HOST)
Migration user: $MIGRATE_USER  (cert auth from $API_HOST)
================================================================
EOF
}

main "$@"
