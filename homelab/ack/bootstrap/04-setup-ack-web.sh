#!/usr/bin/env bash
# 04-setup-ack-web.sh -- Bootstrap ack-web (AHA website) on the ACK network
#
# Runs on: ack-web (10.1.0.247) -- Debian 13 LXC (unprivileged, single-homed)
# CTID: 247
#
# Usage:
#   ./04-setup-ack-web.sh --configure    # Run inside the container
#
# Single-homed on vmbr2 (ACK network, 10.1.0.0/24).
# Runs .NET Kestrel on :5000 serving aha.ackmud.com (Blazor WASM + API).
# nginx-proxy (10.1.0.118) handles TLS termination and proxies here.
#
# Health endpoint: GET /health on :5000

set -euo pipefail

ACK_NET="10.1.0.0/24"
ACK_GW="10.1.0.240"

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

# ---------------------------------------------------------------------------
# Container-side: configure everything
# ---------------------------------------------------------------------------

configure() {
    [[ $EUID -eq 0 ]] || err "Run as root"

    rm -f /root/.env.bootstrap

    disable_ipv6
    configure_dns_resolver
    install_packages
    install_dotnet
    setup_service_user
    clone_repo
    build_and_publish
    install_service
    configure_firewall

    cat <<EOF

================================================================
ack-web is ready (single-homed on ACK network).

IP:     10.1.0.247 (eth0, vmbr2)
Site:   aha.ackmud.com (Blazor WASM + API)
App:    .NET Kestrel on :5000 (no nginx, no TLS)
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
    info "Installing packages"
    apt-get update -qq
    apt-get install -y --no-install-recommends \
        curl ca-certificates chrony iptables git
}

# ---------------------------------------------------------------------------
# .NET 9 SDK (via dotnet-install.sh + caching proxy on nginx-proxy)
# ---------------------------------------------------------------------------

DOTNET_ROOT="/usr/local/dotnet"
DOTNET_CACHE_URL="http://10.1.0.118:8080"
DOTNET_CACHE_DIRECT="https://dotnetcli.azureedge.net"

install_dotnet() {
    if dotnet --list-sdks 2>/dev/null | grep -q "^9\."; then
        info ".NET 9 SDK already installed"
        return
    fi

    local script="/tmp/dotnet-install.sh"
    if [[ ! -f "$script" ]]; then
        curl -fsSL https://dot.net/v1/dotnet-install.sh -o "$script"
        chmod +x "$script"
    fi

    info "Installing .NET 9 SDK via dotnet-install.sh"
    if ! bash "$script" --channel 9.0 --install-dir "$DOTNET_ROOT" --azure-feed "$DOTNET_CACHE_URL" 2>/dev/null; then
        info "Cache unreachable, downloading .NET directly from Microsoft"
        bash "$script" --channel 9.0 --install-dir "$DOTNET_ROOT" --azure-feed "$DOTNET_CACHE_DIRECT"
    fi
    ln -sf "$DOTNET_ROOT/dotnet" /usr/local/bin/dotnet
    info ".NET 9 SDK installed"
}

# ---------------------------------------------------------------------------
# Clone ack-web repo
# ---------------------------------------------------------------------------

clone_repo() {
    local web_dir="/opt/ack-web"

    if [[ -d "$web_dir/.git" ]]; then
        info "web-tng repo already cloned, pulling latest"
        cd "$web_dir" && git pull || true
        return
    fi

    info "Cloning web-tng repo"
    git clone https://github.com/JBailes/web-tng.git "$web_dir"
}

# ---------------------------------------------------------------------------
# Build and publish
# ---------------------------------------------------------------------------

build_and_publish() {
    local web_dir="/opt/ack-web"
    info "Publishing AckWeb.Api"
    cd "$web_dir"
    dotnet publish AckWeb.Api/AckWeb.Api.csproj \
        --configuration Release \
        --output "$web_dir/publish/api"
    chown -R ack-web:ack-web "$web_dir"
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
    useradd --system --no-create-home --shell /usr/sbin/nologin ack-web
}

# ---------------------------------------------------------------------------
# Systemd service
# ---------------------------------------------------------------------------

install_service() {
    local web_dir="/opt/ack-web"
    info "Installing systemd service"
    cp "$web_dir/systemd/ackweb.service" /etc/systemd/system/ackweb.service
    systemctl daemon-reload
    systemctl enable ackweb.service
    systemctl restart ackweb.service
    info "ackweb.service enabled and started"
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

    # Kestrel on :5000 from ACK network (nginx-proxy at 10.1.0.118 connects here)
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
