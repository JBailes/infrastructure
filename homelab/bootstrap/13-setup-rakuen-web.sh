#!/usr/bin/env bash
# 13-setup-rakuen-web.sh -- Create and configure the Rakuen Software website LXC
#
# Runs on: the Proxmox host (creates CT 119, then configures it)
#
# Usage:
#   ./13-setup-rakuen-web.sh               # Create CT and configure
#   ./13-setup-rakuen-web.sh --deploy-only  # Re-run configuration on existing CT
#   ./13-setup-rakuen-web.sh --configure    # (internal) Run inside the container
#
# Creates a Debian 13 LXC (CT 119) single-homed on the LAN:
#   eth0 = 192.168.1.119/23 on vmbr0
#
# Serves rakuensoftware.com as a static site via node serve on :3000.
# nginx-proxy (192.168.1.118) handles TLS termination and proxies here.
#
# The site (RakuenSoftware/rakuensoftware-web) is a Vite + React SPA. It is
# built in-container, so unknown paths must be rewritten to index.html --
# that is what `serve -s` does. Without it /blog 404s on a hard refresh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_LIB="${SCRIPT_DIR}/lib/common.sh"; [[ -f "$_LIB" ]] && source "$_LIB" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Container specification
# ---------------------------------------------------------------------------

CTID=119
HOSTNAME="rakuen-web"
LAN_IP="192.168.1.119"
# Deliberately larger than personal-web (256MB/1core/4GB): this site runs
# `npm install` and a Vite production build inside the container, which OOMs
# at 256MB. The running footprint afterwards is still just `serve`.
RAM=1024
CORES=2
DISK=8
PRIVILEGED="no"

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

# ---------------------------------------------------------------------------
# Host-side: create the container
# ---------------------------------------------------------------------------

host_main() {
    info "Creating rakuen-web container (CTID $CTID)"

    create_lxc "$CTID" "$HOSTNAME" "$LAN_IP" "$RAM" "$CORES" "$DISK" "$ROUTER_GW" "$PRIVILEGED" \
    || { info "Container already exists, deploying config"; }

    pct start "$CTID" 2>/dev/null || true
    sleep 3

    deploy_script "$CTID" "$0"

    info "rakuen-web container ready (CTID $CTID)"
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
rakuen-web is ready.

IP:   $LAN_IP (eth0, vmbr0)
Site: rakuensoftware.com (static files via node serve on :3000)
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
    local site_dir="/opt/rakuen-web"

    if [[ -d "$site_dir/.git" ]]; then
        info "rakuensoftware-web repo already cloned, pulling latest"
        cd "$site_dir" && git pull || true
        return
    fi

    info "Cloning rakuensoftware-web repo"
    git clone https://github.com/RakuenSoftware/rakuensoftware-web.git "$site_dir"
}

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

build_site() {
    local site_dir="/opt/rakuen-web"
    info "Building Rakuen Software site"
    cd "$site_dir"
    npm install --silent
    npm run build
    info "Build complete (output in $site_dir/dist/)"
}

# ---------------------------------------------------------------------------
# Systemd service (serve on :3000)
# ---------------------------------------------------------------------------

install_service() {
    local site_dir="/opt/rakuen-web"
    local serve_bin
    serve_bin="$(npm config get prefix)/bin/serve"
    info "Installing systemd service (serve at $serve_bin)"

    cat > /etc/systemd/system/rakuen-web.service <<EOF
[Unit]
Description=Rakuen Software website (rakuensoftware.com) static file server
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
    systemctl enable rakuen-web.service
    systemctl restart rakuen-web.service
    info "rakuen-web.service enabled and started"
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
