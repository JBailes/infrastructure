#!/usr/bin/env bash
# 00-setup-gateway.sh -- Set up a WOL gateway (active-active pair)
#
# Runs on: wol-gateway-a (10.0.0.200) or wol-gateway-b (10.0.0.201)
#          Debian 13 LXC (privileged, dual-homed)
# Run order: Step 00 (must be up before all other hosts, which need NAT for apt)
#
# Usage:
#   GW_NAME=wol-gateway-a GW_IP=10.0.0.200 ./00-setup-gateway.sh
#   GW_NAME=wol-gateway-b GW_IP=10.0.0.201 ./00-setup-gateway.sh
#
# This is the first script run on the WOL private network. Both gateways
# provide NAT, DNS, and NTP in an active-active configuration. Internal hosts
# use ECMP routing to distribute traffic across both gateways.
#
# The gateway is pure network infrastructure. It does not run application-layer
# services, does not need a SPIRE Agent, and does not have a workload identity.
#
# This script sets up:
#   - NAT masquerading (private hosts reach internet via gateway)
#   - IP forwarding with outbound port filtering (80, 443, 53 only)
#   - IPv6 disabled
#   - chrony NTP server for internal hosts
#   - dnsmasq DNS forwarder for internal hosts
#   - Firewall rules (iptables on all interfaces)
#
# After this script: all other hosts can run apt-get through the gateway's NAT.

set -euo pipefail

# Boot-time secret scrub: remove leftover .env.bootstrap from prior failed runs
rm -f /root/.env.bootstrap

PUBLIC_IFACE="eth0"
PROD_IFACE="eth1"          # vmbr1: prod + shared (10.0.0.0/24)
TEST_IFACE="eth2"          # vmbr3: test (10.0.1.0/24)
PROD_NET="10.0.0.0/24"
TEST_NET="10.0.1.0/24"
PRIVATE_IP="${GW_IP:?Set GW_IP (10.0.0.200 or 10.0.0.201)}"
PRIVATE_IP_TEST="${GW_IP_TEST:?Set GW_IP_TEST (10.0.1.200 or 10.0.1.201)}"
GW_NAME="${GW_NAME:?Set GW_NAME (wol-gateway-a or wol-gateway-b)}"

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

[[ $EUID -eq 0 ]] || err "Run as root"

# ---------------------------------------------------------------------------
# Disable IPv6
# ---------------------------------------------------------------------------

disable_ipv6() {
    info "Disabling IPv6"
    cat > /etc/sysctl.d/99-disable-ipv6.conf <<EOF
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF
    sysctl -p /etc/sysctl.d/99-disable-ipv6.conf
}

# ---------------------------------------------------------------------------
# NAT and IP forwarding (must be early, other hosts depend on this for apt)
# ---------------------------------------------------------------------------

setup_nat() {
    info "Configuring NAT masquerading and IP forwarding"

    # Install iptables (not present in minimal Debian 13 LXC)
    apt-get update -qq
    apt-get install -y --no-install-recommends iptables

    # Enable IP forwarding
    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-ip-forward.conf
    sysctl -w net.ipv4.ip_forward=1

    # Flush all rules for idempotent re-runs
    iptables -t nat -F
    iptables -F FORWARD
    iptables -F INPUT
    iptables -P INPUT ACCEPT
    iptables -P FORWARD ACCEPT

    # NAT masquerade: both prod and test subnets exit via public interface
    iptables -t nat -A POSTROUTING -s "$PROD_NET" -o "$PUBLIC_IFACE" -j MASQUERADE
    iptables -t nat -A POSTROUTING -s "$TEST_NET" -o "$PUBLIC_IFACE" -j MASQUERADE

    # Block forwarding to the home LAN (192.168.0.0/23) except the default gateway.
    # The WOL gateways should only route to 192.168.1.1 (upstream router) and the
    # open internet beyond it, not to other hosts on the home network.
    iptables -A FORWARD -o "$PUBLIC_IFACE" -d 192.168.1.1 -j ACCEPT
    iptables -A FORWARD -o "$PUBLIC_IFACE" -d 192.168.0.0/23 -j DROP

    # Forward rules for prod hosts (vmbr1): HTTP, HTTPS, DNS outbound
    iptables -A FORWARD -i "$PROD_IFACE" -o "$PUBLIC_IFACE" -p tcp --dport 80 -j ACCEPT
    iptables -A FORWARD -i "$PROD_IFACE" -o "$PUBLIC_IFACE" -p tcp --dport 443 -j ACCEPT
    iptables -A FORWARD -i "$PROD_IFACE" -o "$PUBLIC_IFACE" -p udp --dport 53 -j ACCEPT
    iptables -A FORWARD -i "$PROD_IFACE" -o "$PUBLIC_IFACE" -p tcp --dport 53 -j ACCEPT
    iptables -A FORWARD -i "$PUBLIC_IFACE" -o "$PROD_IFACE" -m state --state ESTABLISHED,RELATED -j ACCEPT

    # Forward rules for test hosts (vmbr3): HTTP, HTTPS, DNS outbound
    iptables -A FORWARD -i "$TEST_IFACE" -o "$PUBLIC_IFACE" -p tcp --dport 80 -j ACCEPT
    iptables -A FORWARD -i "$TEST_IFACE" -o "$PUBLIC_IFACE" -p tcp --dport 443 -j ACCEPT
    iptables -A FORWARD -i "$TEST_IFACE" -o "$PUBLIC_IFACE" -p udp --dport 53 -j ACCEPT
    iptables -A FORWARD -i "$TEST_IFACE" -o "$PUBLIC_IFACE" -p tcp --dport 53 -j ACCEPT
    iptables -A FORWARD -i "$PUBLIC_IFACE" -o "$TEST_IFACE" -m state --state ESTABLISHED,RELATED -j ACCEPT

    # No routing between prod and test (they are on separate bridges, no FORWARD rules)

    # Final catch-all DROP for FORWARD chain
    iptables -A FORWARD -j DROP

    # Block inbound from public interface (gateway has no public services)
    iptables -A INPUT -i "$PUBLIC_IFACE" -m state --state ESTABLISHED,RELATED -j ACCEPT
    iptables -A INPUT -i "$PUBLIC_IFACE" -j DROP

    # Install iptables-persistent (actual save happens after firewall setup in persist_iptables)
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends iptables-persistent

    info "NAT enabled for prod ($PROD_NET) and test ($TEST_NET) via $PRIVATE_IP"
}

# ---------------------------------------------------------------------------
# Packages
# ---------------------------------------------------------------------------

install_packages() {
    info "Installing packages"
    apt-get update -qq
    apt-get install -y --no-install-recommends \
        curl ca-certificates iptables \
        chrony dnsmasq
}

# ---------------------------------------------------------------------------
# Firewall (INPUT rules for gateway services)
#
# The public interface lockdown is in setup_nat(). This function adds INPUT
# rules for services on the prod and test interfaces.
# ---------------------------------------------------------------------------

configure_firewall() {
    info "Configuring firewall (prod + test interfaces)"

    # Set default INPUT policy (public interface rules are already in place from setup_nat)
    iptables -P INPUT DROP
    iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    iptables -A INPUT -i lo -j ACCEPT

    # SSH from prod and test subnets
    iptables -A INPUT -s "$PROD_NET" -p tcp --dport 22 -j ACCEPT
    iptables -A INPUT -s "$TEST_NET" -p tcp --dport 22 -j ACCEPT

    # NTP (chrony)
    iptables -A INPUT -s "$PROD_NET" -p udp --dport 123 -j ACCEPT
    iptables -A INPUT -s "$TEST_NET" -p udp --dport 123 -j ACCEPT

    # DNS (dnsmasq)
    iptables -A INPUT -s "$PROD_NET" -p udp --dport 53 -j ACCEPT
    iptables -A INPUT -s "$PROD_NET" -p tcp --dport 53 -j ACCEPT
    iptables -A INPUT -s "$TEST_NET" -p udp --dport 53 -j ACCEPT
    iptables -A INPUT -s "$TEST_NET" -p tcp --dport 53 -j ACCEPT

    info "Firewall configured (iptables)"
}

# ---------------------------------------------------------------------------
# Persist iptables rules (must run AFTER configure_firewall so all rules are saved)
# ---------------------------------------------------------------------------

persist_iptables() {
    info "Persisting iptables rules (NAT + firewall combined)"
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4
}

# ---------------------------------------------------------------------------
# NTP server (chrony)
#
# The gateway is the NTP server for all internal hosts. It syncs to public
# NTP pools via its external interface and serves time on the private network.
# ---------------------------------------------------------------------------

setup_ntp() {
    info "Configuring chrony as NTP server for prod and test networks"
    cat > /etc/chrony/chrony.conf <<CHRONY
# Upstream NTP pools (via gateway's external interface)
pool 2.debian.pool.ntp.org iburst

# Serve time to prod and test subnets
allow $PROD_NET
allow $TEST_NET

bindaddress 0.0.0.0

driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
CHRONY

    systemctl restart chrony
    systemctl enable chrony
    info "Chrony configured: serving NTP to $PROD_NET and $TEST_NET"
}

# ---------------------------------------------------------------------------
# DNS forwarder (dnsmasq)
#
# Internal hosts point their DNS resolver at the gateway. dnsmasq forwards
# queries to upstream DNS servers via the gateway's external interface.
# ---------------------------------------------------------------------------

setup_dns() {
    info "Configuring dnsmasq as DNS forwarder for prod and test networks"
    cat > /etc/dnsmasq.d/wol-gateway.conf <<DNSMASQ
# Listen on prod and test interfaces
interface=$PROD_IFACE
interface=$TEST_IFACE
bind-interfaces

# Forward to upstream resolvers
no-resolv
server=1.1.1.1
server=8.8.8.8

# Local hostname entries for WOL hosts
# Shared infrastructure (reachable from both prod and test)
address=/wol-gateway-a/10.0.0.200
address=/wol-gateway-b/10.0.0.201
address=/spire-server/10.0.0.204
address=/ca/10.0.0.203
address=/provisioning/10.0.0.205
address=/wol-accounts/10.0.0.207
address=/wol-accounts-db/10.0.0.206
address=/spire-db/10.0.0.202
address=/obs/10.0.0.100
address=/wol-a/10.0.0.208
address=/wol-web/10.0.0.209
address=/apt-cache/10.0.0.115
address=/deploy/10.0.0.101
# Prod environment (10.0.0.x, vmbr1)
address=/wol-realm-prod/10.0.0.210
address=/wol-world-prod/10.0.0.211
address=/wol-world-db-prod/10.0.0.213
address=/wol-realm-db-prod/10.0.0.214
address=/wol-ai-prod/10.0.0.212
# Test environment (10.0.1.x, vmbr3)
address=/wol-realm-test/10.0.1.215
address=/wol-world-test/10.0.1.216
address=/wol-world-db-test/10.0.1.218
address=/wol-realm-db-test/10.0.1.219
address=/wol-ai-test/10.0.1.217

cache-size=1000
DNSMASQ

    systemctl restart dnsmasq
    systemctl enable dnsmasq
    info "dnsmasq configured: forwarding DNS on $PROD_IFACE and $TEST_IFACE"
}

# ---------------------------------------------------------------------------
# Proxy configuration (try apt-cache first, fall back to direct)
#
# Gateways are dual-homed and can always reach the internet directly.
# After apt-cache is bootstrapped (step 01), gateways should use it
# for caching benefit. This config is written for future apt-get runs
# (e.g. package updates, promtail install). The initial install_packages
# call runs before apt-cache exists, so it uses direct access.
# ---------------------------------------------------------------------------

configure_proxy_fallback() {
    local proxy_host="10.0.0.115"
    local proxy_port="3128"
    local proxy_url="http://${proxy_host}:${proxy_port}"

    info "Configuring apt proxy with direct fallback"

    # apt: try proxy, fall back to direct on failure
    cat > /etc/apt/apt.conf.d/01proxy <<APTPROXY
// Try the Squid proxy first; fall back to DIRECT if unavailable.
Acquire::http::Proxy "${proxy_url}";
Acquire::https::Proxy "${proxy_url}";
Acquire::http::Proxy::Fallback "DIRECT";
Acquire::https::Proxy::Fallback "DIRECT";
APTPROXY

    # Environment: set proxy with no_proxy for private network
    cat > /etc/profile.d/proxy.sh <<'PROXYENV'
export http_proxy="http://10.0.0.115:3128"
export https_proxy="http://10.0.0.115:3128"
export no_proxy="10.0.0.0/24,10.0.1.0/24,localhost,127.0.0.1"
PROXYENV

    # Trust the Squid CA if it has been distributed
    if [[ -f /usr/local/share/ca-certificates/squid-ca.crt ]]; then
        update-ca-certificates 2>/dev/null
        info "Squid CA trusted"
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    disable_ipv6
    setup_nat
    install_packages
    configure_firewall
    persist_iptables
    setup_ntp
    setup_dns
    configure_proxy_fallback

    cat <<EOF

================================================================
$GW_NAME setup complete.

NAT:    Prod ($PROD_NET via $PROD_IFACE) + Test ($TEST_NET via $TEST_IFACE)
DNS:    dnsmasq on $PROD_IFACE and $TEST_IFACE
NTP:    chrony serving both subnets
Proxy:  apt-cache (10.0.0.115:3128) with direct fallback
LAN:    Blocked (only 192.168.1.1 reachable, no other home LAN hosts)
IPv6:   Disabled

Prod and test are on separate bridges. No routing between them.

Gateway ready. The orchestrator (pve-deploy.sh) will continue
with the next steps automatically.
================================================================
EOF
}

main "$@"
