#!/usr/bin/env bash
# 06-setup-nginx-proxy.sh -- Create and configure the nginx reverse proxy LXC
#
# Runs on: the Proxmox host (creates CT 118, then configures it)
#
# Usage:
#   ./06-setup-nginx-proxy.sh               # Create CT and configure
#   ./06-setup-nginx-proxy.sh --deploy-only  # Re-run configuration on existing CT
#   ./06-setup-nginx-proxy.sh --configure    # (internal) Run inside the container
#
# Creates a Debian 13 LXC (CT 118) tri-homed on all three bridges:
#   eth0 = 192.168.1.118/23 on vmbr0 (LAN, incoming HTTPS from router)
#   eth1 = 10.0.0.118/20 on vmbr1 (WOL, reach wol-web)
#   eth2 = 10.1.0.118/24 on vmbr2 (ACK, reach ack-web)
#
# Central nginx reverse proxy for all web sites. Handles TLS termination
# via certbot and routes by Host header to the appropriate backend:
#   ackmud.com      -> ack-web (10.1.0.247:5000)
#   aha.ackmud.com  -> ack-web (10.1.0.247:5000) + stream for WSS ports
#   bailes.us       -> personal-web (192.168.1.117:3000)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_LIB="${SCRIPT_DIR}/lib/common.sh"; [[ -f "$_LIB" ]] && source "$_LIB" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Container specification
# ---------------------------------------------------------------------------

CTID=118
HOSTNAME="nginx-proxy"
LAN_IP="192.168.1.118"
WOL_IP="10.0.0.118"
ACK_IP="10.1.0.118"
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
    info "Creating nginx-proxy container (CTID $CTID)"

    create_lxc "$CTID" "$HOSTNAME" "$LAN_IP" "$RAM" "$CORES" "$DISK" "$ROUTER_GW" "$PRIVILEGED" \
        --net1 "name=eth1,bridge=${PRIVATE_BRIDGE},ip=${WOL_IP}/20" \
        --net2 "name=eth2,bridge=${ACK_BRIDGE},ip=${ACK_IP}/24" \
    || { info "Container already exists, deploying config"; }

    pct start "$CTID" 2>/dev/null || true
    sleep 3

    deploy_script "$CTID" "$0"

    info "nginx-proxy container ready (CTID $CTID)"
}

# ---------------------------------------------------------------------------
# Container-side: configure everything
# ---------------------------------------------------------------------------

configure() {
    [[ $EUID -eq 0 ]] || err "Run as root"

    rm -f /root/.env.bootstrap

    disable_ipv6
    configure_dns_resolver
    install_packages
    configure_nginx
    configure_dotnet_cache
    configure_firewall
    enable_services
    obtain_certificates

    cat <<EOF

================================================================
nginx-proxy is ready (tri-homed).

LAN:  $LAN_IP (eth0, vmbr0) -- incoming HTTPS from router
WOL:  $WOL_IP (eth1, vmbr1) -- shared/private WOL reachability
ACK:  $ACK_IP (eth2, vmbr2) -- reach ack-web (10.1.0.247:5000)

Routing:
  ackmud.com      -> http://10.1.0.247:5000 (ack-web)
  aha.ackmud.com  -> http://10.1.0.247:5000 (ack-web)
  bailes.us       -> http://192.168.1.117:3000 (personal-web)
  WSS :18890      -> 10.1.0.247:18890
  WSS :8891       -> 10.1.0.247:8891
  WSS :8892       -> 10.1.0.247:8892

Caching proxy:
  :8080 -> dotnetcli.azureedge.net (cached .NET SDK/runtime downloads)

TLS: certbot runs automatically. Renewal via certbot.timer.
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
# DNS (use home router since this host is primarily LAN-facing)
# ---------------------------------------------------------------------------

configure_dns_resolver() {
    info "Configuring DNS resolver"
    cat > /etc/resolv.conf <<RESOLV
nameserver 192.168.1.1
RESOLV
}

# ---------------------------------------------------------------------------
# Packages
# ---------------------------------------------------------------------------

install_packages() {
    info "Installing packages"
    apt-get update -qq
    apt-get install -y --no-install-recommends \
        nginx libnginx-mod-stream certbot python3-certbot-nginx iptables chrony
}

# ---------------------------------------------------------------------------
# .NET SDK caching proxy
#
# Transparently caches downloads from dotnetcli.azureedge.net so that
# dozens of VMs can install .NET without each hitting Microsoft's CDN.
# Clients use dotnet-install.sh --azure-feed http://<this-host>:8080
# ---------------------------------------------------------------------------

configure_dotnet_cache() {
    info "Configuring .NET SDK caching proxy"

    mkdir -p /var/cache/nginx/dotnet

    cat > /etc/nginx/sites-available/dotnet-cache <<'NGINX'
proxy_cache_path /var/cache/nginx/dotnet
    levels=1:2
    keys_zone=dotnet_cache:10m
    max_size=2g
    inactive=30d
    use_temp_path=off;

server {
    listen 8080;
    server_name _;

    location / {
        proxy_pass https://dotnetcli.azureedge.net;
        proxy_ssl_server_name on;
        proxy_set_header Host dotnetcli.azureedge.net;

        proxy_cache dotnet_cache;
        proxy_cache_valid 200 30d;
        proxy_cache_use_stale error timeout updating;
        proxy_cache_lock on;

        add_header X-Cache-Status $upstream_cache_status;
    }
}
NGINX

    ln -sf /etc/nginx/sites-available/dotnet-cache /etc/nginx/sites-enabled/
    nginx -t || err "nginx configuration test failed after adding dotnet cache"
    info ".NET caching proxy configured on port 8080"
}

# ---------------------------------------------------------------------------
# nginx configuration
# ---------------------------------------------------------------------------

configure_nginx() {
    info "Writing nginx configuration"

    # Main HTTP server blocks
    cat > /etc/nginx/sites-available/ackmud.com <<'NGINX'
server {
    listen 80;
    server_name ackmud.com www.ackmud.com;

    location / {
        proxy_pass http://10.1.0.247:5000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
NGINX

    cat > /etc/nginx/sites-available/aha.ackmud.com <<'NGINX'
server {
    listen 80;
    server_name aha.ackmud.com;

    location / {
        proxy_pass http://10.1.0.247:5000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    # Preserve upgrade support for any ACK frontend websocket traffic.
    location /ws {
        proxy_pass http://10.1.0.247:5000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
    }
}
NGINX

    cat > /etc/nginx/sites-available/bailes.us <<'NGINX'
server {
    listen 80;
    server_name bailes.us www.bailes.us;

    location / {
        proxy_pass http://192.168.1.117:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
NGINX

    # Default server: health check endpoint (no Host header needed)
    cat > /etc/nginx/sites-available/default-health <<'NGINX'
server {
    listen 80 default_server;
    server_name _;

    location /health {
        return 200 "ok\n";
        add_header Content-Type text/plain;
    }

    location / {
        return 444;
    }
}
NGINX

    # Enable sites
    rm -f /etc/nginx/sites-enabled/default
    ln -sf /etc/nginx/sites-available/default-health /etc/nginx/sites-enabled/
    ln -sf /etc/nginx/sites-available/ackmud.com /etc/nginx/sites-enabled/
    ln -sf /etc/nginx/sites-available/aha.ackmud.com /etc/nginx/sites-enabled/
    ln -sf /etc/nginx/sites-available/bailes.us /etc/nginx/sites-enabled/

    # Stream blocks for legacy MUD WebSocket proxying
    mkdir -p /etc/nginx/stream.d
    cat > /etc/nginx/stream.d/ack-wss.conf <<'STREAM'
# Legacy MUD WebSocket proxy (TCP passthrough to ack-web)
stream {
    server {
        listen 18890;
        proxy_pass 10.1.0.247:18890;
    }
    server {
        listen 8891;
        proxy_pass 10.1.0.247:8891;
    }
    server {
        listen 8892;
        proxy_pass 10.1.0.247:8892;
    }
}
STREAM

    # Include stream config in main nginx.conf if not already present
    if ! grep -q 'include /etc/nginx/stream.d/' /etc/nginx/nginx.conf; then
        echo 'include /etc/nginx/stream.d/*.conf;' >> /etc/nginx/nginx.conf
    fi

    nginx -t || err "nginx configuration test failed"
    info "nginx configuration written and tested"
}

# ---------------------------------------------------------------------------
# Firewall (iptables)
# ---------------------------------------------------------------------------

configure_firewall() {
    info "Configuring firewall (tri-homed, iptables)"

    iptables -F INPUT 2>/dev/null || true

    iptables -P INPUT DROP
    iptables -P FORWARD DROP
    iptables -P OUTPUT ACCEPT

    iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    iptables -A INPUT -i lo -j ACCEPT

    # HTTP and HTTPS from anywhere (public web traffic via router)
    iptables -A INPUT -p tcp --dport 80 -j ACCEPT
    iptables -A INPUT -p tcp --dport 443 -j ACCEPT

    # .NET caching proxy from all local networks
    iptables -A INPUT -s 192.168.0.0/23 -p tcp --dport 8080 -j ACCEPT
    iptables -A INPUT -s 10.0.0.0/20 -p tcp --dport 8080 -j ACCEPT
    iptables -A INPUT -s 10.1.0.0/24 -p tcp --dport 8080 -j ACCEPT

    # Legacy MUD WSS ports from anywhere
    iptables -A INPUT -p tcp --dport 18890 -j ACCEPT
    iptables -A INPUT -p tcp --dport 8891 -j ACCEPT
    iptables -A INPUT -p tcp --dport 8892 -j ACCEPT

    # SSH from LAN
    iptables -A INPUT -s 192.168.0.0/23 -p tcp --dport 22 -j ACCEPT

    # Persist rules
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4

    # Restore on boot
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
# Enable services
# ---------------------------------------------------------------------------

enable_services() {
    info "Enabling nginx"
    systemctl enable nginx
    systemctl restart nginx
}

# ---------------------------------------------------------------------------
# TLS certificates (certbot)
# ---------------------------------------------------------------------------

CERTBOT_EMAIL="jbailes@gmail.com"

obtain_certificates() {
    info "Obtaining TLS certificates via certbot"

    local failed=0

    # ACK sites (ackmud.com, www, aha)
    if certbot --nginx --non-interactive --agree-tos \
        --email "$CERTBOT_EMAIL" \
        --keep-until-expiring \
        -d ackmud.com -d www.ackmud.com -d aha.ackmud.com; then
        info "Certificate obtained for ackmud.com"
    else
        echo "WARNING: certbot failed for ackmud.com (DNS may not be pointed yet)" >&2
        failed=1
    fi

    # Personal site (bailes.us, www)
    if certbot --nginx --non-interactive --agree-tos \
        --email "$CERTBOT_EMAIL" \
        --keep-until-expiring \
        -d bailes.us -d www.bailes.us; then
        info "Certificate obtained for bailes.us"
    else
        echo "WARNING: certbot failed for bailes.us (DNS may not be pointed yet)" >&2
        failed=1
    fi

    # certbot installs a systemd timer for automatic renewal
    systemctl enable certbot.timer
    systemctl start certbot.timer

    if [[ $failed -eq 1 ]]; then
        cat >&2 <<WARN

================================================================
One or more certbot requests failed. This is expected if DNS is
not yet pointed at $LAN_IP. Once DNS is live, re-run:

  certbot --nginx -d ackmud.com -d www.ackmud.com -d aha.ackmud.com
  certbot --nginx -d bailes.us -d www.bailes.us

Or re-run this script with --deploy-only.
================================================================
WARN
    fi
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
