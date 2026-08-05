#!/usr/bin/env bash
# 06-setup-nginx-proxy.sh -- Create and configure the nginx reverse proxy LXC
#
# Runs on: the Proxmox host (creates the CT, then configures it)
#
# Usage:
#   ./06-setup-nginx-proxy.sh               # Create CT and configure
#   ./06-setup-nginx-proxy.sh --deploy-only  # Re-run configuration on existing CT
#   ./06-setup-nginx-proxy.sh --configure    # (internal) Run inside the container
#
# Creates a Debian 13 LXC dual-homed:
#   eth0 = 192.168.1.<CTID>/23 on vmbr0 (LAN, incoming HTTPS from router)
#   eth1 = 10.1.0.118/24 on vmbr2 (ACK, reach ack-web)
#
# The LAN address follows the CTID. The ACK address does not: ack-gateway's
# dnsmasq has a static entry for 10.1.0.118 and that network is not being
# renumbered.
#
# Central nginx reverse proxy for all web sites. Handles TLS termination
# and routes by Host header to the appropriate backend:
#   ackmud.com      -> ack-web (10.1.0.247:5000) + stream for WSS ports
#   aha.ackmud.com  -> redirect to ackmud.com
#   bailes.us       -> personal-web.bailes.us:3000
#   rakuensoftware.com -> rakuen-web.bailes.us:3000
#   rakuensoft.com  -> redirect to rakuensoftware.com
#
# LAN backends are addressed by name through the internal resolver, so
# renumbering a host does not require editing this config. ACK backends stay
# numeric: that network has its own dnsmasq and is not part of the internal
# zone.
#
# TLS uses HTTP-01 through nginx -- no credentials, no third-party DNS.
# DNS-01 and an internal wildcard are supported but switched off; see CERTS.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_LIB="${SCRIPT_DIR}/lib/common.sh"; [[ -f "$_LIB" ]] && source "$_LIB" 2>/dev/null || true

# This script is pushed into the container on its own, without lib/, so the
# values common.sh would supply need defaults here too. Host-side runs get
# them from common.sh (and therefore from terraform.env when present).
INTERNAL_ZONE="${INTERNAL_ZONE:-bailes.us}"
DNS_IP="${DNS_IP:-192.168.1.101}"
ROUTER_GW="${ROUTER_GW:-192.168.1.1}"

# ---------------------------------------------------------------------------
# Container specification
# ---------------------------------------------------------------------------

CTID="${CTID_NGINX_PROXY:-105}"
HOSTNAME="nginx-proxy"
LAN_IP="192.168.1.${CTID}"
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
        --net1 "name=eth1,bridge=${ACK_BRIDGE},ip=${ACK_IP}/24" \
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
nginx-proxy is ready (dual-homed).

LAN:  $LAN_IP (eth0, vmbr0) -- incoming HTTPS from router
ACK:  $ACK_IP (eth1, vmbr2) -- reach ack-web (10.1.0.247:5000)

Routing:
  ackmud.com      -> http://10.1.0.247:5000 (ack-web)
  aha.ackmud.com  -> https://ackmud.com
  bailes.us       -> http://personal-web.${INTERNAL_ZONE}:3000
  rakuensoftware.com -> http://rakuen-web.${INTERNAL_ZONE}:3000
  rakuensoft.com  -> https://rakuensoftware.com (301)
  WSS :18890      -> 10.1.0.247:18890
  WSS :8891       -> 10.1.0.247:8891
  WSS :8892       -> 10.1.0.247:8892

Caching proxy:
  :8080 -> dotnetcli.azureedge.net (cached .NET SDK/runtime downloads)

TLS: HTTP-01 through nginx. Renewal via certbot.timer.
Certificates: the public sites only. Internal hosts have no public cert;
see CERTS if you ever want a wildcard.
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
    # Internal resolver first so upstreams can be named rather than numbered;
    # the router is kept as a fallback so TLS issuance and proxying keep
    # working if the dns host is down.
    cat > /etc/resolv.conf <<RESOLV
search ${INTERNAL_ZONE}
nameserver ${DNS_IP}
nameserver ${ROUTER_GW}
RESOLV
}

# ---------------------------------------------------------------------------
# Packages
# ---------------------------------------------------------------------------

install_packages() {
    info "Installing packages"
    apt-get update -qq
    apt-get install -y --no-install-recommends \
        nginx libnginx-mod-stream certbot python3-certbot-nginx \
        python3-certbot-dns-cloudflare iptables chrony openssh-client
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

    # Preserve upgrade support for any ACK frontend websocket traffic.
    location /ws {
        proxy_pass http://10.1.0.247:5000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
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

    cat > /etc/nginx/sites-available/bailes.us <<'NGINX'
server {
    listen 80;
    server_name bailes.us www.bailes.us;

    location / {
        proxy_pass http://personal-web.bailes.us:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
NGINX

    cat > /etc/nginx/sites-available/rakuensoftware.com <<'NGINX'
server {
    listen 80;
    server_name rakuensoftware.com www.rakuensoftware.com;

    location / {
        proxy_pass http://rakuen-web.bailes.us:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
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

    # .NET caching proxy from the local networks
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
    systemctl enable nginx
    systemctl restart nginx
}

# ---------------------------------------------------------------------------
# TLS certificates (certbot)
# ---------------------------------------------------------------------------

CERTBOT_EMAIL="${CERTBOT_EMAIL:-jbailes@gmail.com}"
CF_CREDENTIALS="/etc/letsencrypt/cloudflare.ini"

# Certificates to issue: name|comma-separated domains|challenge
#
# HTTP-01 via nginx is the default and needs no credentials -- this is the
# arrangement that has been working, and it is what runs unless you opt in
# to something else.
#
# challenge:
#   any   -- HTTP-01 normally; DNS-01 instead if credentials happen to exist
#   dns   -- DNS-01 only (wildcards). Skipped silently without credentials.
#
# The wildcard entry is commented out deliberately. It would give internal
# hosts publicly-trusted certs, but it requires moving DNS to a provider with
# an API (these domains are at Namecheap) -- a lot of moving parts for a
# convenience. Uncomment it only if you decide that trade is worth making.
CERTS=(
    # "bailes.us-wildcard|bailes.us,*.bailes.us|dns"
    "bailes.us|bailes.us,www.bailes.us|any"
    "ackmud.com|ackmud.com,www.ackmud.com,aha.ackmud.com|any"
    "rakuensoftware.com|rakuensoftware.com,www.rakuensoftware.com|any"
    "rakuensoft.com|rakuensoft.com,www.rakuensoft.com|any"
)

# Internal hosts that consume the wildcard. The deploy hook copies it to
# each after every successful renewal.
# Format: host|destination dir|reload command
CERT_CONSUMERS=(
    "obs.${INTERNAL_ZONE}|/etc/ssl/internal|systemctl reload grafana-server || true"
    "dns.${INTERNAL_ZONE}|/etc/ssl/internal|systemctl restart dns || true"
)

install_cloudflare_credentials() {
    if [[ -f "$CF_CREDENTIALS" ]]; then
        chmod 0600 "$CF_CREDENTIALS"
        info "Cloudflare credentials present -- DNS-01 available"
        return 0
    fi

    if [[ -f /root/secrets/cloudflare.ini ]]; then
        install -m 0600 /root/secrets/cloudflare.ini "$CF_CREDENTIALS"
        rm -f /root/secrets/cloudflare.ini
        info "Installed Cloudflare credentials -- DNS-01 available"
        return 0
    fi

    return 1
}

obtain_certificates() {
    local have_dns01=0
    if install_cloudflare_credentials; then
        have_dns01=1
    else
        info "No Cloudflare credentials -- falling back to HTTP-01 where allowed"
    fi

    local failed=0 skipped_wildcard=0 entry name domains challenge d
    local -a args

    for entry in "${CERTS[@]}"; do
        IFS='|' read -r name domains challenge <<< "$entry"

        if [[ "$challenge" == "dns" && $have_dns01 -eq 0 ]]; then
            echo "SKIP: ${name} needs DNS-01 (wildcard) but no Cloudflare credentials" >&2
            skipped_wildcard=1
            continue
        fi

        args=()
        while IFS= read -r d; do
            [[ -n "$d" ]] && args+=(-d "$d")
        done < <(tr ',' '\n' <<< "$domains")

        # --keep-until-expiring keeps this idempotent, so re-running does not
        # burn Let's Encrypt rate limits on still-valid certificates.
        #
        # rc is captured explicitly: under `set -e` a failing certbot would
        # otherwise abort the whole script, so one unreachable domain would
        # stop the remaining certificates from being issued at all.
        local rc=0
        if [[ $have_dns01 -eq 1 ]]; then
            certbot certonly --non-interactive --agree-tos \
                --email "$CERTBOT_EMAIL" \
                --dns-cloudflare \
                --dns-cloudflare-credentials "$CF_CREDENTIALS" \
                --dns-cloudflare-propagation-seconds 30 \
                --keep-until-expiring \
                --cert-name "$name" \
                "${args[@]}" || rc=$?
        else
            # HTTP-01 through the running nginx. Requires :80 to reach this
            # host from the internet, which is how these sites were issued
            # before the move to DNS-01.
            certbot --nginx --non-interactive --agree-tos \
                --email "$CERTBOT_EMAIL" \
                --keep-until-expiring \
                --cert-name "$name" \
                "${args[@]}" || rc=$?
        fi

        if [[ $rc -eq 0 ]]; then
            info "Certificate obtained for ${name} (${domains})"
        else
            echo "WARNING: certbot failed for ${name}" >&2
            failed=1
        fi
    done

    install_deploy_hook
    systemctl enable certbot.timer
    systemctl start certbot.timer

    if [[ $skipped_wildcard -eq 1 ]]; then
        info "Wildcard not issued (optional; needs DNS-01 credentials)"
    fi

    if [[ $failed -eq 1 ]]; then
        cat >&2 <<WARN

================================================================
One or more certificate requests failed.

Over HTTP-01 this usually means :80 is not reachable from the internet
for that name. Over DNS-01 it means the zone could not be edited with
the supplied Cloudflare token.

Re-run with --deploy-only once corrected.
================================================================
WARN
    fi
}

install_deploy_hook() {
    info "Installing certificate distribution hook"

    local hook_dir="/etc/letsencrypt/renewal-hooks/deploy"
    local hook="${hook_dir}/distribute-wildcard.sh"
    mkdir -p "$hook_dir"

    {
        cat <<'HOOKHEAD'
#!/usr/bin/env bash
# Managed by 06-setup-nginx-proxy.sh -- do not edit by hand.
#
# Runs after each successful renewal. Copies the wildcard certificate to
# the internal services that consume it, then reloads them.
#
# certbot sets RENEWED_LINEAGE to the lineage that just renewed, so a
# public-site renewal does not trigger a pointless fan-out.
set -uo pipefail

LINEAGE="${RENEWED_LINEAGE:-}"
HOOKHEAD

        # Deliberately the wildcard lineage, not the plain bailes.us one:
        # without a wildcard there is nothing worth distributing, and this
        # keeps the hook inert rather than pushing a single-name cert around.
        echo "WILDCARD_LINEAGE=\"/etc/letsencrypt/live/${INTERNAL_ZONE}-wildcard\""

        cat <<'HOOKMID'

[[ "$LINEAGE" == "$WILDCARD_LINEAGE" ]] || exit 0

SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes"

log() { logger -t cert-deploy "$*"; echo "cert-deploy: $*"; }

deploy_to() {
    local host="$1" dest="$2" reload="$3"

    # shellcheck disable=SC2086
    if ! ssh $SSH_OPTS "root@${host}" "mkdir -p ${dest}" 2>/dev/null; then
        log "WARNING: ${host} unreachable, skipping"
        return 1
    fi

    # shellcheck disable=SC2086
    if scp $SSH_OPTS -q \
        "${LINEAGE}/fullchain.pem" "${LINEAGE}/privkey.pem" \
        "root@${host}:${dest}/" 2>/dev/null \
        && ssh $SSH_OPTS "root@${host}" \
            "chmod 0600 ${dest}/privkey.pem; chmod 0644 ${dest}/fullchain.pem; ${reload}" 2>/dev/null; then
        log "deployed wildcard to ${host}"
        return 0
    fi

    log "WARNING: failed to deploy to ${host}"
    return 1
}

HOOKMID

        echo 'CONSUMERS=('
        local c
        for c in "${CERT_CONSUMERS[@]}"; do
            echo "    \"${c}\""
        done
        echo ')'

        cat <<'HOOKTAIL'

for entry in "${CONSUMERS[@]}"; do
    IFS='|' read -r host dest reload <<< "$entry"
    deploy_to "$host" "$dest" "$reload" || true
done

exit 0
HOOKTAIL
    } > "$hook"

    chmod 0755 "$hook"
    info "Deploy hook installed (distributes the wildcard on renewal)"
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
