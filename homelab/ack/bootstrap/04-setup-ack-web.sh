#!/usr/bin/env bash
# 04-setup-ack-web.sh -- Bootstrap ack-web (ackmud.com + aha.ackmud.com) on the ACK network
#
# Runs on: ack-web (10.1.0.247) -- Debian 13 LXC (unprivileged, single-homed)
# CTID: 247
#
# Usage:
#   ./04-setup-ack-web.sh --configure    # Run inside the container
#
# Single-homed on vmbr2 (ACK network, 10.1.0.0/24).
# Runs the ack-web app on :5000 (frontend + node API).
# nginx-proxy (10.1.0.118) handles TLS termination and proxies here.
#
# Health endpoint: GET /health on :5000

set -euo pipefail

ACK_NET="10.1.0.0/24"
ACK_GW="10.1.0.240"
RUNTIME_DIR="/opt/ack-web/runtime"

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
warn() { echo "WARN: $*" >&2; }

# ---------------------------------------------------------------------------
# Container-side: configure everything
# ---------------------------------------------------------------------------

configure() {
    [[ $EUID -eq 0 ]] || err "Run as root"

    rm -f /root/.env.bootstrap

    disable_ipv6
    configure_dns_resolver
    install_packages
    setup_service_user
    stage_repo
    stage_acktng_data
    build_app
    install_service
    configure_firewall

    cat <<EOF

================================================================
ack-web is ready (single-homed on ACK network).

IP:     10.1.0.247 (eth0, vmbr2)
Sites:  ackmud.com + aha.ackmud.com
App:    node server on :5000 (frontend + API, no TLS on host)
Health: GET /health on :5000
TLS:    handled by nginx-proxy (10.1.0.118)

Firewall: :5000 + SSH from $ACK_NET
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
# Packages
# ---------------------------------------------------------------------------

install_packages() {
    local packages=(
        ca-certificates
        chrony
        iptables
        git
    )

    if ! command -v apt-get >/dev/null; then
        warn "apt-get not available; skipping package installation"
        return
    fi

    info "Installing base packages"
    if ! apt-get update -qq; then
        warn "apt-get update failed; assuming required base packages are already present"
        return
    fi

    apt-get install -y --no-install-recommends "${packages[@]}"
}

# ---------------------------------------------------------------------------
# Service user
# ---------------------------------------------------------------------------

setup_service_user() {
    if id ack-web &>/dev/null; then
        info "Service user ack-web already exists"
        return
    fi

    info "Creating service user ack-web"
    useradd --system --create-home --home-dir /var/lib/ack-web --shell /usr/sbin/nologin ack-web
}

# ---------------------------------------------------------------------------
# Stage ack-web source
# ---------------------------------------------------------------------------

stage_repo() {
    local web_dir="/opt/ack-web"
    rm -rf "$web_dir"

    if [[ -d /root/ack-web-src ]]; then
        info "Using staged local ack-web source"
        cp -a /root/ack-web-src "$web_dir"
    else
        info "Cloning web repo"
        git clone https://github.com/ackmudhistoricalarchive/web.git "$web_dir"
    fi

    if [[ -d /root/ack-web-runtime ]]; then
        info "Using staged node runtime"
        rm -rf "$RUNTIME_DIR"
        mkdir -p "$(dirname "$RUNTIME_DIR")"
        cp -a /root/ack-web-runtime "$RUNTIME_DIR"
    fi
}

# ---------------------------------------------------------------------------
# Stage acktng reference data
# ---------------------------------------------------------------------------

stage_acktng_data() {
    local acktng_dir="/opt/acktng"

    if [[ -d /root/acktng-src ]]; then
        info "Using staged acktng data"
        rm -rf "$acktng_dir"
        cp -a /root/acktng-src "$acktng_dir"
        return
    fi

    if [[ -d "$acktng_dir/.git" ]]; then
        info "acktng repo already present, refreshing"
        git -C "$acktng_dir" pull --ff-only || true
        return
    fi

    info "Cloning acktng data repo"
    rm -rf "$acktng_dir"
    git clone https://github.com/ackmudhistoricalarchive/acktng.git "$acktng_dir"
}

# ---------------------------------------------------------------------------
# Build app
# ---------------------------------------------------------------------------

build_app() {
    local web_dir="/opt/ack-web"
    local node_bin="${RUNTIME_DIR}/bin/node"
    local npm_bin="${RUNTIME_DIR}/bin/npm"

    cd "$web_dir"

    if [[ -f "$web_dir/dist/index.html" ]]; then
        info "Using staged ack-web build output"
    elif [[ -x "$npm_bin" ]]; then
        info "Building ack-web app with staged node runtime"
        PATH="${RUNTIME_DIR}/bin:${PATH}" "$npm_bin" ci
        PATH="${RUNTIME_DIR}/bin:${PATH}" "$npm_bin" run build
    elif command -v npm >/dev/null 2>&1; then
        info "Building ack-web app with system npm"
        npm ci
        npm run build
    else
        err "No build output and no npm available. Stage a built web checkout or a node runtime."
    fi

    if [[ ! -f "$web_dir/dist/index.html" ]]; then
        err "ack-web build output missing: $web_dir/dist/index.html"
    fi

    if [[ ! -x "$node_bin" ]] && ! command -v node >/dev/null 2>&1; then
        err "No node runtime available. Stage /root/ack-web-runtime or install node on the host."
    fi

    chown -R ack-web:ack-web "$web_dir" /opt/acktng
}

# ---------------------------------------------------------------------------
# systemd service
# ---------------------------------------------------------------------------

install_service() {
    info "Installing ack-web systemd service"

    local node_exec="/usr/bin/node"
    if [[ -x "${RUNTIME_DIR}/bin/node" ]]; then
        node_exec="${RUNTIME_DIR}/bin/node"
    elif command -v node >/dev/null 2>&1; then
        node_exec="$(command -v node)"
    else
        err "Could not locate a node runtime for ack-web.service"
    fi

    cat > /etc/systemd/system/ack-web.service <<EOF
[Unit]
Description=ACK Historical Archive web app
After=network.target

[Service]
Type=simple
User=ack-web
WorkingDirectory=/opt/ack-web
Environment=PORT=5000
Environment=ACKTNG_DIR=/opt/acktng
Environment=ACKTNG_GAME_URL=http://10.1.0.241:8080
ExecStart=${node_exec} /opt/ack-web/server/app-server.js
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable ack-web.service
    systemctl restart ack-web.service
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

    # ack-web node server on :5000 from ACK network (nginx-proxy at 10.1.0.118 connects here)
    iptables -A INPUT -s "$ACK_NET" -p tcp --dport 5000 -j ACCEPT

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
