#!/usr/bin/env bash
# 06-setup-tngdb.sh -- Bootstrap tngdb (read-only game content API) on the ACK network
#
# Runs on: tngdb (10.1.0.249) -- Debian 13 LXC (unprivileged, single-homed)
# CTID: 249
#
# Usage:
#   ./06-setup-tngdb.sh --configure    # Run inside the container
#
# Single-homed on vmbr2 (ACK network, 10.1.0.0/24).
# Python/FastAPI/asyncpg service on :8000 providing read-only access to
# game content (helps, shelps, lores, skills) from the acktng database.
# Connects to ack-db (10.1.0.246:5432) as ack_readonly.
#
# Health endpoint: GET /health on :8000

set -euo pipefail

ACK_NET="10.1.0.0/24"
ACK_GW="10.1.0.240"
APT_CACHE_IP="10.1.0.115"
APT_CACHE_PORT="3142"
DB_HOST="10.1.0.246"

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

# ---------------------------------------------------------------------------
# Container-side: configure everything
# ---------------------------------------------------------------------------

configure() {
    [[ $EUID -eq 0 ]] || err "Run as root"

    disable_ipv6
    configure_dns_resolver
    configure_apt_proxy
    install_packages
    setup_service_user
    clone_repo
    setup_venv
    setup_env_file
    install_service
    configure_firewall

    cat <<EOF

================================================================
tngdb is ready (single-homed on ACK network).

IP:       10.1.0.249 (eth0, vmbr2)
Service:  Read-only game content API (Python/FastAPI/asyncpg)
Port:     :8000
Health:   GET /health on :8000
Database: ack-db ($DB_HOST:5432), user ack_readonly

Env file: /etc/tngdb/env (set DATABASE_URL before starting)
Firewall: :8000 + SSH from $ACK_NET

Start:    systemctl start tngdb
================================================================
EOF
}

# ---------------------------------------------------------------------------
# Disable IPv6
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
# DNS (use ack-gateway)
# ---------------------------------------------------------------------------

configure_dns_resolver() {
    info "Configuring DNS resolver (ack-gateway)"
    cat > /etc/resolv.conf <<RESOLV
nameserver $ACK_GW
RESOLV
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
# Packages
# ---------------------------------------------------------------------------

install_packages() {
    info "Installing packages"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y --no-install-recommends \
        python3 python3-pip python3-venv \
        curl ca-certificates git iptables
}

# ---------------------------------------------------------------------------
# Service user
# ---------------------------------------------------------------------------

setup_service_user() {
    if id tngdb &>/dev/null; then
        info "Service user tngdb already exists"
        return
    fi
    info "Creating service user tngdb"
    useradd --system --no-create-home --shell /usr/sbin/nologin tngdb
}

# ---------------------------------------------------------------------------
# Clone repo
# ---------------------------------------------------------------------------

clone_repo() {
    local app_dir="/opt/tngdb"

    if [[ -d "$app_dir/.git" ]]; then
        info "tngdb repo already cloned, pulling latest"
        cd "$app_dir" && git pull || true
        return
    fi

    info "Cloning tngdb repo"
    git clone https://github.com/ackmudhistoricalarchive/tngdb.git "$app_dir"
}

# ---------------------------------------------------------------------------
# Python venv and dependencies
# ---------------------------------------------------------------------------

setup_venv() {
    local app_dir="/opt/tngdb"
    info "Setting up Python venv"

    if [[ ! -d "$app_dir/.venv" ]]; then
        python3 -m venv "$app_dir/.venv"
    fi

    "$app_dir/.venv/bin/pip" install --upgrade pip -q
    "$app_dir/.venv/bin/pip" install -r "$app_dir/api/requirements.txt" -q

    chown -R tngdb:tngdb "$app_dir"
    info "Python venv ready"
}

# ---------------------------------------------------------------------------
# Environment file (secrets)
# ---------------------------------------------------------------------------

setup_env_file() {
    local env_dir="/etc/tngdb"
    local env_file="$env_dir/env"

    if [[ -f "$env_file" ]]; then
        info "Environment file already exists at $env_file"
        return
    fi

    info "Creating environment file at $env_file"
    mkdir -p "$env_dir"
    cat > "$env_file" <<ENV
# tngdb environment (managed by bootstrap, not version-controlled)
# Password comes from ack-db: /etc/ack-db-secrets/ack_readonly_password
DATABASE_URL=postgres://ack_readonly:REPLACE_ME@$DB_HOST/acktng
ENV
    chmod 600 "$env_file"
    info "WARNING: set ack_readonly password in DATABASE_URL in $env_file before starting"
}

# ---------------------------------------------------------------------------
# Systemd service
# ---------------------------------------------------------------------------

install_service() {
    info "Installing systemd service"
    cat > /etc/systemd/system/tngdb.service <<UNIT
[Unit]
Description=TNG DB API (read-only game content)
After=network.target

[Service]
Type=exec
User=tngdb
WorkingDirectory=/opt/tngdb
EnvironmentFile=/etc/tngdb/env
ExecStart=/opt/tngdb/.venv/bin/uvicorn api.main:app --host 0.0.0.0 --port 8000
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable tngdb.service
    info "tngdb.service enabled (not started, set DATABASE_URL first)"
}

# ---------------------------------------------------------------------------
# Firewall (iptables)
# ---------------------------------------------------------------------------

configure_firewall() {
    info "Configuring firewall (single-homed, ACK network only)"

    iptables -F INPUT 2>/dev/null || true

    iptables -P INPUT DROP
    iptables -P FORWARD DROP
    iptables -P OUTPUT ACCEPT

    iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    iptables -A INPUT -i lo -j ACCEPT

    # API on :8000 from ACK network
    iptables -A INPUT -s "$ACK_NET" -p tcp --dport 8000 -j ACCEPT

    # SSH from ACK network
    iptables -A INPUT -s "$ACK_NET" -p tcp --dport 22 -j ACCEPT

    # Persist rules
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4

    cat > /etc/systemd/system/iptables-restore.service <<EOF
[Unit]
Description=Restore iptables rules
Before=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=/sbin/iptables-restore /etc/iptables/rules.v4

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable iptables-restore

    info "Firewall configured (iptables)"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if [[ "${1:-}" == "--configure" ]]; then
    configure
else
    echo "Usage: $0 --configure (run inside the container)"
    echo "This script is deployed via pve-setup-ack.sh"
    exit 1
fi
