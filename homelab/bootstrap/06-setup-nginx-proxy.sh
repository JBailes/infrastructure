#!/usr/bin/env bash
# 06-setup-nginx-proxy.sh -- Create and configure the nginx reverse proxy LXC
#
# Runs on: the Proxmox host (creates CT 105, then configures it)
#
# Usage:
#   ./06-setup-nginx-proxy.sh               # Create CT and configure
#   ./06-setup-nginx-proxy.sh --deploy-only  # Re-run configuration on existing CT
#   ./06-setup-nginx-proxy.sh --configure    # (internal) Run inside the container
#
# Creates a Debian 13 LXC dual-homed:
#   eth0 on vmbr0 (LAN, incoming HTTPS from router)
#   eth1 on vmbr2 (ACK, reach ack-web)
#
# The vmbr1 (WOL) interface was removed with the WOL decommission.
#
# Central nginx reverse proxy for all web sites. Handles TLS termination
# via certbot and routes by Host header to the appropriate backend:
#   ackmud.com      -> ack-web (ack-web:5000) + stream for WSS ports
#   aha.ackmud.com  -> redirect to ackmud.com
#   bailes.us       -> personal-web (personal-web:3000)
#   rakuensoftware.com -> rakuen-web (rakuen-web:3000)
#   rakuensoft.com  -> redirect to rakuensoftware.com
#
# Backends are addressed by DNS name, not by address. The dns container serves
# the bailes.us zone from live Proxmox state (15-setup-dns.sh) and PVE hands
# every container that resolver, so a container can be renumbered without
# editing this file -- ack-web included, which this script used to reach by
# address because it had no record. Addresses appear below only where something
# must be allocated or where the value cannot be a name: this container's own
# interfaces and firewall source ranges. The resolver's own address is the other
# unavoidable one ($DNS_IP below): it is what makes names resolvable, so it
# cannot itself be a name.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_LIB="${SCRIPT_DIR}/lib/common.sh"; [[ -f "$_LIB" ]] && source "$_LIB" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Container specification
# ---------------------------------------------------------------------------

CTID="${NGINX_PROXY_CTID:-105}"
HOSTNAME="nginx-proxy"
LAN_IP="192.168.1.${CTID}"
ACK_IP="10.1.0.118"
RAM=512
CORES=1
DISK=4
PRIVILEGED="no"

# The dns container (CT 101) serves the bailes.us zone. This is the one address
# that cannot be a name: it is what makes name resolution work in the first
# place. PVE writes both of these into the container's /etc/resolv.conf.
DNS_IP="192.168.1.101"
SEARCH_DOMAIN="bailes.us"

# Backends, by name. Renumbering a backend is a DNS change, not an edit here.
# Spelled out in full rather than composed from $SEARCH_DOMAIN so that a reader
# grepping for a backend hostname finds it.
PERSONAL_WEB="personal-web.bailes.us"
RAKUEN_WEB="rakuen-web.bailes.us"

# ack-web sits on the ACK bridge. It used to be named here by address because it
# had no record; 15-setup-dns.sh now builds the zone from live Proxmox state, so
# it has one and this is a name like the rest.
ACK_WEB="ack-web"

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

# ---------------------------------------------------------------------------
# Host-side: create the container
# ---------------------------------------------------------------------------

host_main() {
    info "Creating nginx-proxy container (CTID $CTID)"

    # --nameserver/--searchdomain make PVE own /etc/resolv.conf, which is what
    # lets the vhosts below address backends by name. create_lxc does not set
    # onboot (only the VM helper does), so pass it explicitly -- otherwise every
    # site behind this proxy stays down after a host reboot.
    create_lxc "$CTID" "$HOSTNAME" "$LAN_IP" "$RAM" "$CORES" "$DISK" "$ROUTER_GW" "$PRIVILEGED" \
        --net1 "name=eth1,bridge=${ACK_BRIDGE},ip=${ACK_IP}/24" \
        --nameserver "$DNS_IP" \
        --searchdomain "$SEARCH_DOMAIN" \
        --onboot 1 \
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
    verify_dns
    install_packages
    configure_nginx
    configure_dotnet_cache
    configure_firewall
    enable_services
    obtain_certificates

    cat <<EOF

================================================================
nginx-proxy is ready (CT $CTID, dual-homed).

LAN:  eth0 on vmbr0 -- incoming HTTPS from router
ACK:  eth1 on vmbr2 -- reach ack-web

Routing:
  ackmud.com      -> ack-web :5000
  aha.ackmud.com  -> https://ackmud.com
  bailes.us       -> $PERSONAL_WEB:3000 (CT 106)
  rakuensoftware.com -> $RAKUEN_WEB:3000 (CT 107)
  rakuensoft.com  -> https://rakuensoftware.com (301)
  WSS :18890 :8891 :8892 -> ack-web

Backends resolve through the dns container (CT 101) at request time, so a
backend can be renumbered in DNS without touching this proxy.

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
# DNS
#
# /etc/resolv.conf is PVE's, written from the container's --nameserver and
# --searchdomain. This used to overwrite it to point at the home router, which
# cannot resolve the bailes.us zone -- so the vhosts below would fail to parse
# and nginx would refuse to start. Check rather than overwrite.
# ---------------------------------------------------------------------------

# The resolver the vhosts below hand to nginx. Taken from resolv.conf rather than
# hardcoded so there is one source of truth -- if the resolver ever moves, PVE
# rewrites this file and the generated nginx config follows on the next deploy.
resolver_addr() {
    local addr
    addr=$(awk '/^nameserver/ { print $2; exit }' /etc/resolv.conf)
    [[ -n "$addr" ]] || err "no nameserver in /etc/resolv.conf -- was this container created with --nameserver?"
    echo "$addr"
}

verify_dns() {
    info "Verifying backend name resolution via $(resolver_addr)"
    local unresolved=()
    local name
    for name in "$PERSONAL_WEB" "$RAKUEN_WEB"; do
        getent hosts "$name" >/dev/null || unresolved+=("$name")
    done
    if [[ ${#unresolved[@]} -gt 0 ]]; then
        err "cannot resolve: ${unresolved[*]} -- is the dns container (CT 101) up, and is this container's --nameserver set to it?"
    fi
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

    local resolver
    resolver=$(resolver_addr)

    # Main HTTP server blocks
    # These heredocs are unquoted so the backend constants above expand.
    # nginx's own runtime variables are escaped as \$.
    cat > /etc/nginx/sites-available/ackmud.com <<NGINX
server {
    listen 80;
    server_name ackmud.com www.ackmud.com;

    location / {
        proxy_pass http://${ACK_WEB}:5000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    # Preserve upgrade support for any ACK frontend websocket traffic.
    location /ws {
        proxy_pass http://${ACK_WEB}:5000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 1d;
    }
}
NGINX

    cat > /etc/nginx/sites-available/aha.ackmud.com <<'NGINX'
server {
    listen 80;
    server_name aha.ackmud.com;
    return 301 https://ackmud.com$request_uri;
}
NGINX

    # A named backend must be resolved at request time, not at config-parse
    # time. Written literally, nginx resolves it while reading the config, and a
    # resolver that is not answering yet -- as on a cold boot, where this
    # container and the dns container start together -- is a fatal config error.
    # nginx then refuses to start and stays down, taking every site on this
    # proxy with it until someone restarts it by hand. Going through a variable
    # defers the lookup to the request, so a slow resolver costs one failed
    # request instead of the whole proxy.
    cat > /etc/nginx/sites-available/bailes.us <<NGINX
server {
    listen 80;
    server_name bailes.us www.bailes.us;

    resolver ${resolver} valid=30s ipv6=off;
    set \$backend ${PERSONAL_WEB}:3000;

    location / {
        proxy_pass http://\$backend\$request_uri;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
NGINX

    cat > /etc/nginx/sites-available/rakuensoftware.com <<NGINX
server {
    listen 80;
    server_name rakuensoftware.com www.rakuensoftware.com;

    resolver ${resolver} valid=30s ipv6=off;
    set \$backend ${RAKUEN_WEB}:3000;

    location / {
        proxy_pass http://\$backend\$request_uri;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
NGINX

    cat > /etc/nginx/sites-available/rakuensoft.com <<'NGINX'
server {
    listen 80;
    server_name rakuensoft.com www.rakuensoft.com;
    return 301 https://rakuensoftware.com$request_uri;
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
    ln -sf /etc/nginx/sites-available/rakuensoftware.com /etc/nginx/sites-enabled/
    ln -sf /etc/nginx/sites-available/rakuensoft.com /etc/nginx/sites-enabled/

    # Stream blocks for legacy MUD WebSocket proxying
    mkdir -p /etc/nginx/stream.d
    cat > /etc/nginx/stream.d/ack-wss.conf <<STREAM
# Legacy MUD WebSocket proxy (TCP passthrough to ack-web)
stream {
    server {
        listen 18890;
        proxy_pass ${ACK_WEB}:18890;
    }
    server {
        listen 8891;
        proxy_pass ${ACK_WEB}:8891;
    }
    server {
        listen 8892;
        proxy_pass ${ACK_WEB}:8892;
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
    info "Configuring firewall (dual-homed, iptables)"

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

    # nginx runs ExecStartPre=nginx -t and systemd gives up if it fails. Any
    # dependency that is merely slow at boot -- DNS is the one that has bitten
    # us -- therefore leaves every site on this proxy down until a human
    # notices. Retry instead: the cause is usually gone seconds later.
    #
    # 20 tries at 5s apart keeps retrying for ~100s, which comfortably outlasts
    # the dns container coming up alongside this one. It is deliberately finite:
    # a genuine config error should end in `failed` where monitoring can see it,
    # not loop forever looking healthy-ish.
    mkdir -p /etc/systemd/system/nginx.service.d
    cat > /etc/systemd/system/nginx.service.d/restart.conf <<'UNIT'
[Unit]
# Do not start before the resolver the vhosts depend on can be reached.
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=20

[Service]
Restart=on-failure
RestartSec=5
UNIT

    systemctl daemon-reload
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

    # ACK Historical Archive
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

    # Rakuen Software site (rakuensoftware.com, www)
    if certbot --nginx --non-interactive --agree-tos \
        --email "$CERTBOT_EMAIL" \
        --keep-until-expiring \
        -d rakuensoftware.com -d www.rakuensoftware.com; then
        info "Certificate obtained for rakuensoftware.com"
    else
        echo "WARNING: certbot failed for rakuensoftware.com (DNS may not be pointed yet)" >&2
        failed=1
    fi

    # Short domain (rakuensoft.com, www) -- redirects to rakuensoftware.com.
    # It still needs its own certificate, otherwise https://rakuensoft.com
    # fails TLS before nginx ever gets to issue the redirect.
    if certbot --nginx --non-interactive --agree-tos \
        --email "$CERTBOT_EMAIL" \
        --keep-until-expiring \
        -d rakuensoft.com -d www.rakuensoft.com; then
        info "Certificate obtained for rakuensoft.com"
    else
        echo "WARNING: certbot failed for rakuensoft.com (DNS may not be pointed yet)" >&2
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
  certbot --nginx -d rakuensoftware.com -d www.rakuensoftware.com
  certbot --nginx -d rakuensoft.com -d www.rakuensoft.com

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
