#!/usr/bin/env bash
# 03-setup-ack-db.sh -- Set up ACK! PostgreSQL database host
#
# Runs on: ack-db (10.1.0.246) -- Debian 13 LXC (unprivileged, single-homed)
#
# Provides:
#   - PostgreSQL 17 with acktng database
#   - Users: ack (read/write), ack_readonly (read-only)
#   - Self-signed SSL certificate
#   - postgres_exporter on :9187 (scraped by Prometheus on obs)
#   - Firewall: PostgreSQL from ACK network, postgres_exporter from obs
#   - IPv6 disabled
#   - DNS via ack-gateway, apt proxy via apt-cache
#
# Idempotent: safe to re-run. Existing database and users are preserved.

set -euo pipefail

DB_IP="10.1.0.246"
DB_NAME="acktng"
DB_USER="ack"
DB_READONLY_USER="ack_readonly"
GW_IP="10.1.0.240"
ACK_NET="10.1.0.0/24"
LAN_NET="192.168.1.0/23"
OBS_IP="10.1.0.100"
APT_CACHE_IP="10.1.0.115"
APT_CACHE_PORT="3142"
PG_EXPORTER_VERSION="0.16.0"

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
warn() { echo "WARN: $*" >&2; }

[[ $EUID -eq 0 ]] || err "Run as root"

# ---------------------------------------------------------------------------
# Disable IPv6
# ---------------------------------------------------------------------------

disable_ipv6() {
    info "Disabling IPv6"
    cat > /etc/sysctl.d/99-disable-ipv6.conf <<EOF
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF
    sysctl -p /etc/sysctl.d/99-disable-ipv6.conf
}

# ---------------------------------------------------------------------------
# Network: DNS and default route
# ---------------------------------------------------------------------------

configure_network() {
    info "Configuring DNS and default route via ACK! gateway"

    cat > /etc/resolv.conf <<EOF
nameserver $GW_IP
EOF

    ip route del default 2>/dev/null || true
    ip route add default via "$GW_IP"
    info "Default route set via $GW_IP"
}

# ---------------------------------------------------------------------------
# apt proxy (apt-cacher-ng on apt-cache host)
# ---------------------------------------------------------------------------

configure_apt_proxy() {
    info "Configuring apt proxy ($APT_CACHE_IP:$APT_CACHE_PORT)"
    mkdir -p /etc/apt/apt.conf.d
    echo "Acquire::http::Proxy \"http://${APT_CACHE_IP}:${APT_CACHE_PORT}\";" \
        > /etc/apt/apt.conf.d/01proxy
}

# ---------------------------------------------------------------------------
# Install PostgreSQL 17
# ---------------------------------------------------------------------------

install_postgresql() {
    if command -v psql &>/dev/null && psql --version | grep -q "17"; then
        info "PostgreSQL 17 already installed"
        return
    fi

    info "Installing PostgreSQL 17"
    export DEBIAN_FRONTEND=noninteractive

    apt-get update -qq
    apt-get install -y --no-install-recommends \
        curl ca-certificates gnupg lsb-release sudo

    # Add pgdg repository
    if [[ ! -f /etc/apt/sources.list.d/pgdg.list ]]; then
        curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
            | gpg --dearmor -o /usr/share/keyrings/postgresql-archive-keyring.gpg
        echo "deb [signed-by=/usr/share/keyrings/postgresql-archive-keyring.gpg] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
            > /etc/apt/sources.list.d/pgdg.list
        apt-get update -qq
    fi

    apt-get install -y --no-install-recommends postgresql-17
    info "PostgreSQL 17 installed"
}

# ---------------------------------------------------------------------------
# Self-signed SSL certificate
# ---------------------------------------------------------------------------

configure_ssl() {
    local ssl_dir="/etc/postgresql/17/main/ssl"
    local cert_file="$ssl_dir/server.crt"
    local key_file="$ssl_dir/server.key"

    if [[ -f "$cert_file" && -f "$key_file" ]]; then
        info "SSL certificate already exists, skipping"
        return
    fi

    info "Generating self-signed SSL certificate"
    mkdir -p "$ssl_dir"

    openssl req -new -x509 -days 3650 -nodes \
        -subj "/CN=ack-db" \
        -addext "subjectAltName=IP:${DB_IP}" \
        -keyout "$key_file" \
        -out "$cert_file"

    chown postgres:postgres "$cert_file" "$key_file"
    chmod 600 "$key_file"
    chmod 644 "$cert_file"
    info "SSL certificate generated"
}

# ---------------------------------------------------------------------------
# PostgreSQL configuration
# ---------------------------------------------------------------------------

configure_postgresql() {
    info "Configuring PostgreSQL"

    local pg_conf="/etc/postgresql/17/main/postgresql.conf"
    local hba_conf="/etc/postgresql/17/main/pg_hba.conf"
    local ssl_dir="/etc/postgresql/17/main/ssl"

    # postgresql.conf overrides
    cat > /etc/postgresql/17/main/conf.d/ack.conf <<PGCONF
listen_addresses = '${DB_IP}, 127.0.0.1'
port = 5432
max_connections = 50

ssl = on
ssl_cert_file = '${ssl_dir}/server.crt'
ssl_key_file = '${ssl_dir}/server.key'

logging_collector = on
log_directory = '/var/log/postgresql'
log_filename = 'postgresql-%Y-%m-%d.log'
log_min_duration_statement = 500
PGCONF

    # pg_hba.conf (overwrite: we own this host entirely)
    cat > "$hba_conf" <<HBA
# TYPE  DATABASE  USER           ADDRESS          METHOD

# Local unix socket (trust for postgres superuser, used by bootstrap)
local   all       postgres                        peer

# ACK MUD servers (read/write)
hostssl ${DB_NAME}  ${DB_USER}           ${ACK_NET}       scram-sha-256

# Read-only from ACK network and LAN (for tngdb API)
hostssl ${DB_NAME}  ${DB_READONLY_USER}  ${ACK_NET}       scram-sha-256
hostssl ${DB_NAME}  ${DB_READONLY_USER}  ${LAN_NET}       scram-sha-256

# Reject everything else
host    all       all            0.0.0.0/0        reject
HBA

    # Ensure log directory exists
    mkdir -p /var/log/postgresql
    chown postgres:postgres /var/log/postgresql

    systemctl restart postgresql
    info "PostgreSQL configured and restarted"
}

# ---------------------------------------------------------------------------
# Create database and users
# ---------------------------------------------------------------------------

create_database() {
    # Check if database already exists
    if sudo -u postgres psql -lqt | cut -d '|' -f 1 | grep -qw "$DB_NAME"; then
        info "Database '$DB_NAME' already exists, skipping creation"
    else
        info "Creating database '$DB_NAME'"
        sudo -u postgres createdb "$DB_NAME"
    fi

    # Create ack user (idempotent)
    if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" | grep -q 1; then
        info "User '$DB_USER' already exists"
    else
        info "Creating user '$DB_USER'"
        local ack_pass
        ack_pass=$(openssl rand -base64 24)
        sudo -u postgres psql -c "CREATE USER ${DB_USER} WITH PASSWORD '${ack_pass}'"
        sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER}"
        sudo -u postgres psql -d "$DB_NAME" -c "GRANT ALL ON SCHEMA public TO ${DB_USER}"

        mkdir -p /etc/ack-db-secrets
        echo "$ack_pass" > /etc/ack-db-secrets/ack_password
        chmod 600 /etc/ack-db-secrets/ack_password
        info "Password written to /etc/ack-db-secrets/ack_password"
    fi

    # Create ack_readonly user (idempotent)
    if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${DB_READONLY_USER}'" | grep -q 1; then
        info "User '$DB_READONLY_USER' already exists"
    else
        info "Creating user '$DB_READONLY_USER'"
        local readonly_pass
        readonly_pass=$(openssl rand -base64 24)
        sudo -u postgres psql -c "CREATE USER ${DB_READONLY_USER} WITH PASSWORD '${readonly_pass}'"
        sudo -u postgres psql -d "$DB_NAME" -c "GRANT USAGE ON SCHEMA public TO ${DB_READONLY_USER}"
        sudo -u postgres psql -d "$DB_NAME" -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO ${DB_READONLY_USER}"

        mkdir -p /etc/ack-db-secrets
        echo "$readonly_pass" > /etc/ack-db-secrets/ack_readonly_password
        chmod 600 /etc/ack-db-secrets/ack_readonly_password
        info "Password written to /etc/ack-db-secrets/ack_readonly_password"
    fi

    info "Database and users ready"
}

# ---------------------------------------------------------------------------
# postgres_exporter
# ---------------------------------------------------------------------------

install_postgres_exporter() {
    if [[ -f /usr/local/bin/postgres_exporter ]]; then
        info "postgres_exporter already installed"
    else
        info "Installing postgres_exporter v${PG_EXPORTER_VERSION}"
        local arch
        arch=$(dpkg --print-architecture)
        local tarball="postgres_exporter-${PG_EXPORTER_VERSION}.linux-${arch}.tar.gz"
        local url="https://github.com/prometheus-community/postgres_exporter/releases/download/v${PG_EXPORTER_VERSION}/${tarball}"
        curl -fsSL --connect-timeout 30 --retry 3 --retry-delay 5 "$url" -o "/tmp/${tarball}"
        tar -xzf "/tmp/${tarball}" -C /tmp/
        cp "/tmp/postgres_exporter-${PG_EXPORTER_VERSION}.linux-${arch}/postgres_exporter" /usr/local/bin/
        rm -rf "/tmp/${tarball}" "/tmp/postgres_exporter-${PG_EXPORTER_VERSION}.linux-${arch}"
    fi

    # Systemd unit (idempotent: overwrite)
    cat > /etc/systemd/system/postgres-exporter.service <<'UNIT'
[Unit]
Description=Prometheus PostgreSQL Exporter
After=postgresql.service
Wants=postgresql.service

[Service]
Type=simple
User=postgres
Environment=DATA_SOURCE_NAME=host=/var/run/postgresql dbname=acktng sslmode=disable
ExecStart=/usr/local/bin/postgres_exporter --web.listen-address=:9187
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload
    systemctl enable postgres-exporter
    systemctl restart postgres-exporter
    info "postgres_exporter running on :9187"
}

# ---------------------------------------------------------------------------
# Firewall
# ---------------------------------------------------------------------------

configure_firewall() {
    info "Configuring firewall"

    apt-get install -y --no-install-recommends iptables

    # Flush existing rules for idempotent re-runs
    iptables -F INPUT
    iptables -F OUTPUT
    iptables -F FORWARD

    # Default policies
    iptables -P INPUT DROP
    iptables -P FORWARD DROP
    iptables -P OUTPUT ACCEPT

    # Loopback
    iptables -A INPUT -i lo -j ACCEPT

    # Established/related
    iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

    # SSH from ACK network
    iptables -A INPUT -s "$ACK_NET" -p tcp --dport 22 -j ACCEPT

    # PostgreSQL from ACK network
    iptables -A INPUT -s "$ACK_NET" -p tcp --dport 5432 -j ACCEPT

    # PostgreSQL from LAN (ack_readonly for tngdb API)
    iptables -A INPUT -s "$LAN_NET" -p tcp --dport 5432 -j ACCEPT

    # postgres_exporter from obs only
    iptables -A INPUT -s "$OBS_IP" -p tcp --dport 9187 -j ACCEPT

    # Persist rules
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends iptables-persistent
    iptables-save > /etc/iptables/rules.v4

    info "Firewall configured"
}

# ---------------------------------------------------------------------------
# Container-side main
# ---------------------------------------------------------------------------

configure() {
    info "Setting up ack-db ($DB_IP)"

    disable_ipv6
    configure_network
    configure_apt_proxy
    install_postgresql
    configure_ssl
    configure_postgresql
    create_database
    install_postgres_exporter
    configure_firewall

    cat <<EOF

================================================================
ack-db setup complete ($DB_IP).

PostgreSQL:         $DB_IP:5432
Database:           $DB_NAME
Users:              $DB_USER (read/write), $DB_READONLY_USER (read-only)
SSL:                Self-signed (CN=ack-db)
postgres_exporter:  $DB_IP:9187

Passwords stored in /etc/ack-db-secrets/ (root-only).

Next steps:
  1. pg_dump from existing host (192.168.1.112)
  2. pg_restore into this host
  3. Update data/db.conf on each MUD server to point to $DB_IP
  4. Restart MUD servers
================================================================
EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if [[ "${1:-}" == "--configure" ]]; then
    configure
else
    configure
fi
