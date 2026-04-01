#!/usr/bin/env bash
# 18-setup-wol-web.sh -- Prepare wol-web host environment
#
# Runs on: wol-web (10.0.0.209) -- Debian 13 LXC (unprivileged, single-homed)
# Run order: Step 16 (after shared infrastructure is up)
#
# This script sets up the host environment for the WOL web frontend:
#   - Single-homed networking (private WOL network only)
#   - IPv6 disabled
#   - ECMP routing and DNS/NTP via gateways
#   - .NET 9 ASP.NET Core runtime (Kestrel on :5000)
#   - Firewall: SSH + port 5000 from private net
#   - Service user and directory structure
#
# Site served: ackmud.com (Blazor WASM, WOL client)
# Backend: Kestrel (.NET) on :5000 (no nginx, no TLS)
# TLS termination: handled by nginx-proxy (10.0.0.118)
# Internal API: wol-accounts (10.0.0.207:8443) via mTLS on private network
#
# Health endpoint: GET /health on :5000 (app-level, not host-level)

set -euo pipefail
_LIB="$(dirname "$0")/lib/common.sh"; [[ -f "$_LIB" ]] || _LIB="/root/lib/common.sh"; source "$_LIB"
scrub_bootstrap_secrets

PROD_NET="10.0.0.0/24"
TEST_NET="10.0.1.0/24"
WEB_DIR="/opt/wol-web"
ACCOUNTS_IP="10.0.0.207"

[[ $EUID -eq 0 ]] || err "Run as root"

# ---------------------------------------------------------------------------
# Packages
# ---------------------------------------------------------------------------

install_base_packages() {
    info "Installing base packages"
    apt-get update -qq
    apt-get install -y --no-install-recommends \
        curl ca-certificates chrony iptables
}

# ---------------------------------------------------------------------------
# .NET 9 ASP.NET Core runtime (via common.sh)
# ---------------------------------------------------------------------------

install_dotnet() {
    install_dotnet_runtime
}

# ---------------------------------------------------------------------------
# Service user and directory structure
# ---------------------------------------------------------------------------

setup_service_user() {
    if id wol-web &>/dev/null; then
        info "Service user wol-web already exists"
        return
    fi

    info "Creating service user and directory structure"
    useradd --system --no-create-home --shell /usr/sbin/nologin wol-web
    mkdir -p "$WEB_DIR"
    chown wol-web:wol-web "$WEB_DIR"
}

# ---------------------------------------------------------------------------
# Systemd service
# ---------------------------------------------------------------------------

install_service() {
    info "Installing systemd service"
    cat > /etc/systemd/system/wolweb.service <<EOF
[Unit]
Description=WOL Web (ackmud.com)
After=network-online.target
Wants=network-online.target

[Service]
Type=exec
User=wol-web
Group=wol-web
WorkingDirectory=${WEB_DIR}/publish
ExecStart=${WEB_DIR}/publish/WolWeb.Host
Restart=always
RestartSec=5
LimitNOFILE=65536
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=${WEB_DIR}
StandardOutput=journal
StandardError=journal
SyslogIdentifier=wolweb

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable wolweb.service
    info "wolweb.service enabled. Service will start once binary is deployed."
}

# ---------------------------------------------------------------------------
# Firewall (iptables, single-homed on private network)
# ---------------------------------------------------------------------------

configure_firewall() {
    info "Configuring firewall (single-homed, private network only)"

    iptables -F INPUT 2>/dev/null || true

    iptables -P INPUT DROP
    iptables -P FORWARD DROP
    iptables -P OUTPUT ACCEPT

    iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    iptables -A INPUT -i lo -j ACCEPT

    # SSH from private network
    iptables -A INPUT -s "$PROD_NET" -p tcp --dport 22 -j ACCEPT
    iptables -A INPUT -s "$TEST_NET" -p tcp --dport 22 -j ACCEPT

    # Kestrel app server (nginx-proxy connects here)
    iptables -A INPUT -s "$PROD_NET" -p tcp --dport 5000 -j ACCEPT
    iptables -A INPUT -s "$TEST_NET" -p tcp --dport 5000 -j ACCEPT

    info "Firewall configured: SSH + :5000 from $PROD_NET and $TEST_NET"
}

persist_iptables() {
    info "Persisting iptables rules"
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    info "Setting up wol-web host (ackmud.com)"

    disable_ipv6
    install_base_packages
    configure_dns
    configure_ntp
    install_dotnet
    setup_service_user
    install_service
    configure_firewall
    persist_iptables

    cat <<EOF

================================================================
wol-web host environment is ready (single-homed).

Site: ackmud.com (Blazor WASM, WOL client)

App server: .NET Kestrel on :5000 (no nginx, no TLS)
Health:     GET /health on :5000
TLS:        handled by nginx-proxy (10.0.0.118)
Internal:   wol-accounts at $ACCOUNTS_IP:8443

Deploy the published binary via pve-build-services.sh.

Network: single-homed on WOL private network (10.0.0.0/24 + 10.0.1.0/24)
Firewall: SSH + :5000 from private net only
================================================================
EOF
}

main "$@"
