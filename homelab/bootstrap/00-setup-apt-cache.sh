#!/usr/bin/env bash
# 00-setup-apt-cache.sh -- Create and configure the apt-cache LXC
#
# Runs on: the Proxmox host (creates CT 115, then configures it)
# Run order: Step 00 (first homelab host, before all others)
#
# Usage:
#   ./00-setup-apt-cache.sh               # Create CT and configure
#   ./00-setup-apt-cache.sh --deploy-only  # Re-run configuration on existing CT
#   ./00-setup-apt-cache.sh --configure    # (internal) Run inside the container
#
# Creates a dual-homed Debian 13 LXC (CT 115):
#   eth0 = 192.168.1.115/23 on vmbr0 (LAN, fetches and serves packages)
#   eth1 = 10.1.0.115/24 on vmbr2 (ACK private network, serves cached packages)
#
# Provides an apt package cache for homelab and ACK hosts. apt-cacher-ng
# caches .deb packages on first download and serves them from cache on
# subsequent requests.
#
# After this script: LAN hosts configure apt to use
# http://apt-cache.bailes.us:3142 as their proxy. ACK hosts have no internal
# DNS, so they use http://10.1.0.115:3142 directly.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ===================================================================
# In-container configuration (runs inside CT 115)
# ===================================================================

configure() {
    err()  { echo "ERROR: $*" >&2; exit 1; }
    info() { echo "==> $*"; }

    rm -f /root/.env.bootstrap

    # Derived, not hardcoded: the LAN address follows the CTID, so pinning it
    # here just produces a banner that lies after a renumber.
    EXTERNAL_IP="$(ip -4 -o addr show dev eth0 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}')"
    EXTERNAL_IP="${EXTERNAL_IP:-unknown}"
    ACK_IP="10.1.0.115"
    ACK_NET="10.1.0.0/24"
    LAN_NET="192.168.0.0/23"
    CACHE_PORT="3142"
    DNS_IP="192.168.1.101"
    INTERNAL_ZONE="bailes.us"

    [[ $EUID -eq 0 ]] || err "Run as root"

    # -- Network (dual-homed: LAN for fetching, ACK network for serving)
    configure_network() {
        info "Configuring DNS and NTP"
        # Internal DNS first (resolves *.bailes.us and forwards the rest to
        # the router); public resolvers as a fallback so package fetches keep
        # working even if the dns host is down.
        cat > /etc/resolv.conf <<EOF
search ${INTERNAL_ZONE}
nameserver ${DNS_IP}
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF

        if command -v chronyc &>/dev/null; then
            cat > /etc/chrony/chrony.conf <<EOF
pool 2.debian.pool.ntp.org iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
EOF
            systemctl restart chrony 2>/dev/null || true
        fi
    }

    # -- Packages
    install_packages() {
        info "Installing packages"
        export DEBIAN_FRONTEND=noninteractive

        # The apt-cache must fetch directly from the internet, not through itself.
        rm -f /etc/apt/apt.conf.d/*proxy* /etc/apt/apt.conf.d/*cacher*
        sed -i '/Acquire::http::Proxy/d' /etc/apt/apt.conf 2>/dev/null || true

        apt-get update -qq
        apt-get install -y --no-install-recommends \
            apt-cacher-ng ca-certificates iptables chrony curl socat
    }

    # -- apt-cacher-ng configuration
    configure_cache() {
        info "Configuring apt-cacher-ng"
        cat > /etc/apt-cacher-ng/acng.conf <<ACNG
# Homelab apt package cache
# Listen on all interfaces (firewall restricts access)
BindAddress: 0.0.0.0
Port: ${CACHE_PORT}

# Cache directory
CacheDir: /var/cache/apt-cacher-ng

# Logging
LogDir: /var/log/apt-cacher-ng
ExTreshold: 4

# Pass through HTTPS (no interception, just tunnel)
PassThroughPattern: .*
ACNG

        systemctl enable apt-cacher-ng
        systemctl restart apt-cacher-ng
        info "apt-cacher-ng running on 0.0.0.0:${CACHE_PORT}"
    }

    # -- Firewall
    configure_firewall() {
        info "Configuring iptables firewall"

        # Flush existing rules (container-scoped, safe in LXC)
        iptables -F
        iptables -X

        # Default policies
        iptables -P INPUT DROP
        iptables -P FORWARD DROP
        iptables -P OUTPUT ACCEPT

        # Allow loopback
        iptables -A INPUT -i lo -j ACCEPT

        # Allow established/related connections
        iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

        # SSH from the LAN
        iptables -A INPUT -s "$LAN_NET" -p tcp --dport 22 -j ACCEPT

        # apt-cacher-ng from the LAN and the ACK network
        iptables -A INPUT -s "$ACK_NET" -p tcp --dport "$CACHE_PORT" -j ACCEPT
        iptables -A INPUT -s "$LAN_NET" -p tcp --dport "$CACHE_PORT" -j ACCEPT

        # Health check from the LAN and the ACK network
        iptables -A INPUT -s "$LAN_NET" -p tcp --dport 8080 -j ACCEPT
        iptables -A INPUT -s "$ACK_NET" -p tcp --dport 8080 -j ACCEPT

        info "iptables firewall configured"
    }

    # -- Health check endpoint
    setup_health_check() {
        info "Setting up health check endpoint on :8080"

        cat > /usr/local/bin/apt-cache-health <<'HEALTH'
#!/usr/bin/env bash
read -r request
if systemctl is-active --quiet apt-cacher-ng 2>/dev/null; then
    echo -e "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nok"
else
    echo -e "HTTP/1.1 503 Service Unavailable\r\nContent-Type: text/plain\r\n\r\napt-cacher-ng not running"
fi
HEALTH
        chmod 755 /usr/local/bin/apt-cache-health

        cat > /etc/systemd/system/apt-cache-health.service <<SERVICE
[Unit]
Description=apt-cache health check endpoint
After=apt-cacher-ng.service

[Service]
Type=simple
ExecStart=/usr/bin/socat TCP-LISTEN:8080,fork,reuseaddr EXEC:/usr/local/bin/apt-cache-health
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
SERVICE

        systemctl daemon-reload
        systemctl enable --now apt-cache-health
        info "Health check endpoint running on :8080"
    }

    # -- Run in-container setup
    info "Setting up apt-cache package cache (${EXTERNAL_IP})"

    configure_network
    install_packages
    configure_cache
    configure_firewall
    setup_health_check

    cat <<EOF

================================================================
apt-cache setup complete (apt-cache.${INTERNAL_ZONE}:${CACHE_PORT}).

apt-cacher-ng caches .deb packages for all internal hosts.
Other HTTP/HTTPS traffic goes directly through the router.

Networks served:
  LAN:  ${EXTERNAL_IP}:${CACHE_PORT} (vmbr0)
  ACK:  ${ACK_IP}:${CACHE_PORT} (vmbr2)

LAN hosts should set:
  Acquire::http::Proxy "http://apt-cache.${INTERNAL_ZONE}:${CACHE_PORT}";
ACK hosts (no internal DNS) should set:
  Acquire::http::Proxy "http://${ACK_IP}:${CACHE_PORT}";
================================================================
EOF
}

# ===================================================================
# Host-side: create CT and deploy (runs on the Proxmox host)
# ===================================================================

host_main() {
    source "$SCRIPT_DIR/lib/common.sh"
    [[ $EUID -eq 0 ]] || err "Run as root"

    local ctid="$CTID_APT_CACHE"
    local hostname="apt-cache"
    local ip="192.168.1.${ctid}"
    local deploy_only=0
    [[ "${1:-}" == "--deploy-only" ]] && deploy_only=1

    if [[ $deploy_only -eq 0 ]]; then
        if create_lxc "$ctid" "$hostname" "$ip" 512 1 32 "$ROUTER_GW" "no"; then
            # Add ACK private network (dual-homed: LAN + ACK)
            pct set "$ctid" --net1 "name=eth1,bridge=${ACK_BRIDGE},ip=10.1.0.115/24"
            info "Dual-homing configured: net1 on ${ACK_BRIDGE} (10.1.0.115/24)"

            pct start "$ctid"
            info "CREATED: CT $ctid ($hostname) at $ip"
        fi
    fi

    # Verify CT is running before deploying
    if ! pct status "$ctid" 2>/dev/null | grep -q "running"; then
        pct start "$ctid" 2>/dev/null || err "CT $ctid is not running and could not be started"
    fi

    info "Deploying $hostname configuration (CT $ctid)"
    deploy_script "$ctid" "$SCRIPT_DIR/00-setup-apt-cache.sh"
    register_dns "$hostname" "$ip"
}

# ===================================================================
# Dispatch: host-side vs in-container
# ===================================================================

if [[ "${1:-}" == "--configure" ]]; then
    configure
else
    host_main "$@"
fi
