#!/usr/bin/env bash
# 05-setup-tng-ai.sh -- Bootstrap tng-ai (NPC dialogue AI) on the ACK network
#
# Runs on: tng-ai (10.1.0.248) -- Debian 13 LXC (unprivileged, single-homed)
# CTID: 248
#
# Usage:
#   ./05-setup-tng-ai.sh --configure    # Run inside the container
#
# Single-homed on vmbr2 (ACK network, 10.1.0.0/24).
# Python/FastAPI service on :8000 providing NPC dialogue via Groq LLM API.
# Called by acktng at TNGAI_URL (http://10.1.0.248:8000/v1/chat).
#
# Health endpoint: GET /health on :8000
#
# The GROQ_API_KEY must be provided in /etc/tng-ai/env before the service
# can process chat requests. The health endpoint returns 200 regardless.

set -euo pipefail

ACK_NET="10.1.0.0/24"
ACK_GW="10.1.0.240"
APT_CACHE_IP="10.1.0.115"
APT_CACHE_PORT="3142"

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
tng-ai is ready (single-homed on ACK network).

IP:       10.1.0.248 (eth0, vmbr2)
Service:  NPC dialogue AI (Python/FastAPI/Groq)
Port:     :8000
Health:   GET /health on :8000
API:      POST /v1/chat on :8000

Env file: /etc/tng-ai/env (set GROQ_API_KEY before starting)
Firewall: :8000 + SSH from $ACK_NET

Start:    systemctl start tng-ai
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
    if id tng-ai &>/dev/null; then
        info "Service user tng-ai already exists"
        return
    fi
    info "Creating service user tng-ai"
    useradd --system --no-create-home --shell /usr/sbin/nologin tng-ai
}

# ---------------------------------------------------------------------------
# Clone repo
# ---------------------------------------------------------------------------

clone_repo() {
    local app_dir="/opt/tng-ai"

    if [[ -d "$app_dir/.git" ]]; then
        info "tng-ai repo already cloned, pulling latest"
        cd "$app_dir" && git pull || true
        return
    fi

    info "Cloning tng-ai repo"
    git clone https://github.com/JBailes/tng-ai.git "$app_dir"
}

# ---------------------------------------------------------------------------
# Python venv and dependencies
# ---------------------------------------------------------------------------

setup_venv() {
    local app_dir="/opt/tng-ai"
    info "Setting up Python venv"

    if [[ ! -d "$app_dir/.venv" ]]; then
        python3 -m venv "$app_dir/.venv"
    fi

    "$app_dir/.venv/bin/pip" install --upgrade pip -q
    "$app_dir/.venv/bin/pip" install -r "$app_dir/requirements.txt" -q

    chown -R tng-ai:tng-ai "$app_dir"
    info "Python venv ready"
}

# ---------------------------------------------------------------------------
# Environment file (secrets)
# ---------------------------------------------------------------------------

setup_env_file() {
    local env_dir="/etc/tng-ai"
    local env_file="$env_dir/env"

    if [[ -f "$env_file" ]]; then
        info "Environment file already exists at $env_file"
        return
    fi

    info "Creating environment file at $env_file"
    mkdir -p "$env_dir"
    cat > "$env_file" <<ENV
# tng-ai environment (managed by bootstrap, not version-controlled)
GROQ_API_KEY=REPLACE_ME
DEFAULT_PROVIDER=groq
DEFAULT_MODEL=llama-3.3-70b-versatile
ENV
    chmod 600 "$env_file"
    info "WARNING: set GROQ_API_KEY in $env_file before starting the service"
}

# ---------------------------------------------------------------------------
# Systemd service
# ---------------------------------------------------------------------------

install_service() {
    info "Installing systemd service"
    cat > /etc/systemd/system/tng-ai.service <<UNIT
[Unit]
Description=TNG AI Service (NPC dialogue)
After=network.target

[Service]
Type=exec
User=tng-ai
WorkingDirectory=/opt/tng-ai
EnvironmentFile=/etc/tng-ai/env
ExecStart=/opt/tng-ai/.venv/bin/uvicorn app.main:app --host 0.0.0.0 --port 8000
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable tng-ai.service
    info "tng-ai.service enabled (not started, set GROQ_API_KEY first)"
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
