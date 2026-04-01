#!/usr/bin/env bash
# 00-setup-ack-gateway.sh -- Set up ACK! MUD network gateway
#
# Runs on: ack-gateway (10.1.0.240 / 192.168.1.240) -- Debian 13 LXC (privileged, dual-homed)
#
# Provides:
#   - NAT masquerading for ACK! hosts to reach the internet
#   - Port forwarding: external game ports -> internal MUD servers
#   - DNS forwarding (dnsmasq) for the ACK! network
#   - IPv6 disabled
#   - Outbound port filtering (80, 443, 53 only)
#
# Port mapping:
#   8890 -> 10.1.0.241:4000 (acktng)
#   8891 -> 10.1.0.242:4000 (ack431)
#   8892 -> 10.1.0.243:4000 (ack42)
#   8893 -> 10.1.0.244:4000 (ack41)
#   8894 -> 10.1.0.245:4000 (assault30)
#   8895 -> 10.1.0.250:4000 (ackfuss)

set -euo pipefail

EXTERNAL_IF="eth0"
INTERNAL_IF="eth1"
INTERNAL_IP="10.1.0.240"
INTERNAL_NET="10.1.0.0/24"
EXTERNAL_GW="192.168.1.1"

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
# NAT and IP forwarding
# ---------------------------------------------------------------------------

setup_nat() {
    info "Configuring NAT and IP forwarding"

    apt-get update -qq
    apt-get install -y --no-install-recommends iptables

    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-ip-forward.conf
    sysctl -w net.ipv4.ip_forward=1

    iptables -t nat -F
    iptables -F FORWARD

    # NAT masquerade: ACK! network traffic exits via external interface
    iptables -t nat -A POSTROUTING -s "$INTERNAL_NET" -o "$EXTERNAL_IF" -j MASQUERADE

    # Forward rules: allow outbound HTTP, HTTPS, DNS
    iptables -A FORWARD -i "$INTERNAL_IF" -o "$EXTERNAL_IF" -p tcp --dport 80 -j ACCEPT
    iptables -A FORWARD -i "$INTERNAL_IF" -o "$EXTERNAL_IF" -p tcp --dport 443 -j ACCEPT
    iptables -A FORWARD -i "$INTERNAL_IF" -o "$EXTERNAL_IF" -p udp --dport 53 -j ACCEPT
    iptables -A FORWARD -i "$INTERNAL_IF" -o "$EXTERNAL_IF" -p tcp --dport 53 -j ACCEPT
    iptables -A FORWARD -i "$EXTERNAL_IF" -o "$INTERNAL_IF" -m state --state ESTABLISHED,RELATED -j ACCEPT

    # Allow return/established traffic from internal MUD servers back to external clients
    iptables -A FORWARD -i "$INTERNAL_IF" -o "$EXTERNAL_IF" -m state --state ESTABLISHED,RELATED -j ACCEPT

    # Allow forwarded game traffic (port forwarding, new connections after DNAT)
    iptables -A FORWARD -i "$EXTERNAL_IF" -o "$INTERNAL_IF" -p tcp --dport 4000 -j ACCEPT

    # Drop everything else
    iptables -A FORWARD -j DROP

    # Block unsolicited inbound on external interface (except port-forwarded game traffic)
    iptables -A INPUT -i "$EXTERNAL_IF" -m state --state ESTABLISHED,RELATED -j ACCEPT
    iptables -A INPUT -i "$EXTERNAL_IF" -j DROP

    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends iptables-persistent

    info "NAT enabled"
}

# ---------------------------------------------------------------------------
# Port forwarding: external game ports -> internal MUD servers
# ---------------------------------------------------------------------------

setup_port_forwarding() {
    info "Configuring port forwarding for MUD servers"

    # Port -> MUD server mapping
    # External port 8890-8894 on the gateway's external IP
    # forwarded to port 4000 on each MUD server's internal IP

    iptables -t nat -A PREROUTING -i "$EXTERNAL_IF" -p tcp --dport 8890 -j DNAT --to-destination 10.1.0.241:4000
    iptables -t nat -A PREROUTING -i "$EXTERNAL_IF" -p tcp --dport 8891 -j DNAT --to-destination 10.1.0.242:4000
    iptables -t nat -A PREROUTING -i "$EXTERNAL_IF" -p tcp --dport 8892 -j DNAT --to-destination 10.1.0.243:4000
    iptables -t nat -A PREROUTING -i "$EXTERNAL_IF" -p tcp --dport 8893 -j DNAT --to-destination 10.1.0.244:4000
    iptables -t nat -A PREROUTING -i "$EXTERNAL_IF" -p tcp --dport 8894 -j DNAT --to-destination 10.1.0.245:4000
    iptables -t nat -A PREROUTING -i "$EXTERNAL_IF" -p tcp --dport 8895 -j DNAT --to-destination 10.1.0.250:4000

    info "Port forwarding configured"
    info "  8890 -> 10.1.0.241:4000 (acktng)"
    info "  8891 -> 10.1.0.242:4000 (ack431)"
    info "  8892 -> 10.1.0.243:4000 (ack42)"
    info "  8893 -> 10.1.0.244:4000 (ack41)"
    info "  8894 -> 10.1.0.245:4000 (assault30)"
    info "  8895 -> 10.1.0.250:4000 (ackfuss)"
}

# ---------------------------------------------------------------------------
# Packages
# ---------------------------------------------------------------------------

install_packages() {
    info "Installing packages"
    apt-get update -qq
    apt-get install -y --no-install-recommends \
        curl ca-certificates dnsmasq
}

# ---------------------------------------------------------------------------
# DNS forwarder (dnsmasq)
# ---------------------------------------------------------------------------

setup_dns() {
    info "Configuring dnsmasq"
    cat > /etc/dnsmasq.d/ack-gateway.conf <<DNSMASQ
interface=$INTERNAL_IF
bind-interfaces

no-resolv
server=1.1.1.1
server=8.8.8.8

# ACK! host entries
address=/ack-gateway/10.1.0.240
address=/acktng/10.1.0.241
address=/ack431/10.1.0.242
address=/ack42/10.1.0.243
address=/ack41/10.1.0.244
address=/assault30/10.1.0.245
address=/ackfuss/10.1.0.250
address=/ack-db/10.1.0.246
address=/ack-web/10.1.0.247
address=/tng-ai/10.1.0.248
address=/tngdb/10.1.0.249
address=/apt-cache/10.1.0.115
address=/obs/10.1.0.100
address=/deploy/10.1.0.101
address=/nginx-proxy/10.1.0.118

cache-size=500
DNSMASQ

    systemctl restart dnsmasq
    systemctl enable dnsmasq
    info "dnsmasq configured on $INTERNAL_IP"
}

# ---------------------------------------------------------------------------
# Persist iptables
# ---------------------------------------------------------------------------

persist_iptables() {
    info "Persisting iptables rules"
    iptables-save > /etc/iptables/rules.v4
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    info "Setting up ACK! gateway ($INTERNAL_IP)"

    disable_ipv6
    setup_nat
    setup_port_forwarding
    install_packages
    setup_dns
    persist_iptables

    cat <<EOF

================================================================
ACK! gateway setup complete ($INTERNAL_IP).

NAT:   Active (ACK! hosts can reach internet)
DNS:   dnsmasq on $INTERNAL_IP:53
Ports: 8890-8895 forwarded to MUD servers on :4000

Game server mapping:
  8890 -> 10.1.0.241:4000 (acktng)
  8891 -> 10.1.0.242:4000 (ack431)
  8892 -> 10.1.0.243:4000 (ack42)
  8893 -> 10.1.0.244:4000 (ack41)
  8894 -> 10.1.0.245:4000 (assault30)
  8895 -> 10.1.0.250:4000 (ackfuss)
================================================================
EOF
}

main "$@"
