#!/usr/bin/env bash
# 07-setup-personal-web.sh -- Create and configure the personal website LXC
#
# Runs on: the Proxmox host (creates CT 117, then configures it)
#
# Usage:
#   ./07-setup-personal-web.sh               # Create CT and configure
#   ./07-setup-personal-web.sh --deploy-only  # Re-run configuration on existing CT
#   ./07-setup-personal-web.sh --configure    # (internal) Run inside the container
#
# Creates a Debian 13 LXC (CT 117) single-homed on the LAN:
#   eth0 = 192.168.1.117/23 on vmbr0
#
# Serves bailes.us as a static site via node serve on :3000.
# nginx-proxy (192.168.1.118) handles TLS termination and proxies here.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_LIB="${SCRIPT_DIR}/lib/common.sh"; [[ -f "$_LIB" ]] && source "$_LIB" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Container specification
# ---------------------------------------------------------------------------

CTID=117
HOSTNAME="personal-web"
LAN_IP="192.168.1.117"
RAM=256
CORES=1
DISK=4
PRIVILEGED="no"

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

# ---------------------------------------------------------------------------
# Host-side: create the container
# ---------------------------------------------------------------------------

host_main() {
    info "Creating personal-web container (CTID $CTID)"

    create_lxc "$CTID" "$HOSTNAME" "$LAN_IP" "$RAM" "$CORES" "$DISK" "$ROUTER_GW" "$PRIVILEGED" \
    || { info "Container already exists, deploying config"; }

    pct start "$CTID" 2>/dev/null || true
    sleep 3

    deploy_script "$CTID" "$0"

    info "personal-web container ready (CTID $CTID)"
}

# ---------------------------------------------------------------------------
# Container-side: configure everything
# ---------------------------------------------------------------------------

configure() {
    [[ $EUID -eq 0 ]] || err "Run as root"

    rm -f /root/.env.bootstrap

    disable_ipv6
    install_packages
    install_serve
    clone_site
    build_site
    install_service
    configure_firewall

    cat <<EOF

================================================================
personal-web is ready.

IP:   $LAN_IP (eth0, vmbr0)
Site: bailes.us (static files via node serve on :3000)
TLS:  handled by nginx-proxy (192.168.1.118)

Firewall: :3000 from LAN (192.168.0.0/23), SSH from LAN
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
# Packages
# ---------------------------------------------------------------------------

install_packages() {
    info "Installing packages"
    apt-get update -qq
    apt-get install -y --no-install-recommends \
        curl ca-certificates chrony iptables nodejs npm git
}

# ---------------------------------------------------------------------------
# Static file server (serve)
# ---------------------------------------------------------------------------

install_serve() {
    local serve_bin
    serve_bin="$(npm config get prefix)/bin/serve"
    if [[ -x "$serve_bin" ]]; then
        info "serve already installed at $serve_bin"
        return
    fi
    info "Installing serve (static file server)"
    npm install -g serve
    serve_bin="$(npm config get prefix)/bin/serve"
    [[ -x "$serve_bin" ]] || err "serve not found after install (expected $serve_bin)"
    info "serve installed at $serve_bin"
}

# ---------------------------------------------------------------------------
# Clone site repo
# ---------------------------------------------------------------------------

clone_site() {
    local site_dir="/opt/personal-web"

    if [[ -d "$site_dir/.git" ]]; then
        info "web-personal repo already cloned, pulling latest"
        cd "$site_dir" && git pull || true
        return
    fi

    info "Cloning web-personal repo"
    git clone https://github.com/JBailes/web-personal.git "$site_dir"
}

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

build_site() {
    local site_dir="/opt/personal-web"
    info "Building personal site"
    cd "$site_dir"
    npm install --silent
    npm run build
    info "Build complete (output in $site_dir/dist/)"
}

# ---------------------------------------------------------------------------
# Systemd service (serve on :3000)
# ---------------------------------------------------------------------------

install_service() {
    local site_dir="/opt/personal-web"
    local serve_bin
    serve_bin="$(npm config get prefix)/bin/serve"
    info "Installing systemd service (serve at $serve_bin)"

    cat > /etc/systemd/system/personal-web.service <<EOF
[Unit]
Description=Personal website (bailes.us) static file server
After=network.target

[Service]
Type=simple
ExecStart=$serve_bin -s $site_dir/dist -l 3000
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable personal-web.service
    systemctl restart personal-web.service
    info "personal-web.service enabled and started"
}

# ---------------------------------------------------------------------------
# Firewall (iptables)
# ---------------------------------------------------------------------------

configure_firewall() {
    info "Configuring firewall (single-homed, LAN only)"

    iptables -F INPUT 2>/dev/null || true

    iptables -P INPUT DROP
    iptables -P FORWARD DROP
    iptables -P OUTPUT ACCEPT

    iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    iptables -A INPUT -i lo -j ACCEPT

    # serve on :3000 from LAN (nginx-proxy connects here)
    iptables -A INPUT -s 192.168.0.0/23 -p tcp --dport 3000 -j ACCEPT

    # SSH from LAN
    iptables -A INPUT -s 192.168.0.0/23 -p tcp --dport 22 -j ACCEPT

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
elif [[ "${1:-}" == "--deploy-only" ]]; then
    pct start "$CTID" 2>/dev/null || true
    sleep 3
    deploy_script "$CTID" "$0"
else
    host_main
fi
