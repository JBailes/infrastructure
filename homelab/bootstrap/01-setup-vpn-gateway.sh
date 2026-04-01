#!/usr/bin/env bash
# 01-setup-vpn-gateway.sh -- Create and configure the VPN gateway VM
#
# Runs on: the Proxmox host (creates VM 104, then configures it)
# Run order: Step 01 (after apt-cache)
#
# Usage:
#   ./01-setup-vpn-gateway.sh               # Create VM and configure
#   ./01-setup-vpn-gateway.sh --deploy-only  # Re-run configuration on existing VM
#   ./01-setup-vpn-gateway.sh --configure    # (internal) Run inside the VM
#
# Creates a Debian 13 cloud-init VM (VMID 104):
#   eth0 = 192.168.1.104/23 on vmbr0 (LAN)
#
# Prerequisites (must exist alongside this script before running):
#   secrets/client.ovpn   -- OpenVPN client config file
#   secrets/auth.txt      -- credentials file (username on line 1, password on line 2)
#
# This VM acts as a VPN gateway for the LAN. Any device that sets its
# default gateway (and DNS) to 192.168.1.104 will have all traffic routed
# through the VPN tunnel. A kill switch ensures forwarded traffic is NEVER
# sent unencrypted.
#
# Why a VM (not LXC): LXC containers share the host kernel's network
# namespace, which prevents iptables FORWARD from receiving transit traffic.
# A VM has its own kernel, so IP forwarding works correctly.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ===================================================================
# In-VM configuration (runs inside VM 104)
# ===================================================================

configure() {
    VPN_IFACE="tun0"
    LAN_IFACE=$(ip -4 route show default | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
    [[ -n "$LAN_IFACE" ]] || { echo "ERROR: could not detect LAN interface from default route" >&2; exit 1; }
    SECRETS_DIR="/root/secrets"
    VPN_CONF_SRC="${SECRETS_DIR}/client.ovpn"
    VPN_AUTH_SRC="${SECRETS_DIR}/auth.txt"
    APT_CACHE="192.168.1.115"
    APT_CACHE_PORT="3142"

    err()  { echo "ERROR: $*" >&2; exit 1; }
    info() { echo "==> $*"; }

    [[ $EUID -eq 0 ]] || err "Run as root"

    # -- Validate prerequisites
    validate_inputs() {
        info "Validating prerequisites"
        [[ -d "$SECRETS_DIR" ]] || err "secrets/ directory not found at $SECRETS_DIR"
        [[ -f "$VPN_CONF_SRC" ]] || err "OpenVPN config not found at $VPN_CONF_SRC"
        [[ -f "$VPN_AUTH_SRC" ]] || err "Credentials file not found at $VPN_AUTH_SRC"

        local line_count
        line_count=$(wc -l < "$VPN_AUTH_SRC")
        [[ "$line_count" -ge 2 ]] || err "auth.txt must have at least 2 lines (username, password)"

        info "Prerequisites OK"
    }

    # -- apt proxy
    configure_apt_proxy() {
        info "Configuring apt proxy (apt-cache at ${APT_CACHE}:${APT_CACHE_PORT})"
        mkdir -p /etc/apt/apt.conf.d
        cat > /etc/apt/apt.conf.d/01proxy <<APTPROXY
Acquire::http::Proxy "http://${APT_CACHE}:${APT_CACHE_PORT}";
APTPROXY
    }

    # -- Disable systemd-resolved (must happen before installing dnsmasq)
    disable_resolved() {
        if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
            systemctl stop systemd-resolved
            systemctl disable systemd-resolved
            rm -f /etc/resolv.conf
            echo "nameserver 1.1.1.1" > /etc/resolv.conf
            info "Disabled systemd-resolved (port 53 conflict with dnsmasq)"
        fi
    }

    # -- Packages
    install_packages() {
        info "Installing packages"
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
            openvpn iptables iptables-persistent dnsmasq curl ca-certificates qemu-guest-agent
        systemctl enable --now qemu-guest-agent
    }

    # -- OpenVPN configuration
    setup_openvpn() {
        info "Installing OpenVPN configuration"

        cp "$VPN_AUTH_SRC" /etc/openvpn/auth.txt
        chmod 0600 /etc/openvpn/auth.txt

        cp "$VPN_CONF_SRC" /etc/openvpn/client.conf

        if grep -q '^auth-user-pass' /etc/openvpn/client.conf; then
            sed -i 's|^auth-user-pass.*|auth-user-pass /etc/openvpn/auth.txt|' /etc/openvpn/client.conf
        else
            echo 'auth-user-pass /etc/openvpn/auth.txt' >> /etc/openvpn/client.conf
        fi

        if ! grep -q 'update-dns.sh' /etc/openvpn/client.conf; then
            cat >> /etc/openvpn/client.conf <<'HOOKS'

# DNS update hooks (added by bootstrap)
script-security 2
up /etc/openvpn/update-dns.sh
down /etc/openvpn/update-dns.sh
HOOKS
        fi

        VPN_REMOTE=$(awk '/^remote[[:space:]]+/ {print $2; exit}' /etc/openvpn/client.conf)
        VPN_PORT=$(awk '/^remote[[:space:]]+/ {print $3; exit}' /etc/openvpn/client.conf)
        VPN_PROTO=$(awk '/^proto[[:space:]]+/ {print $2; exit}' /etc/openvpn/client.conf)

        [[ -n "$VPN_REMOTE" ]] || err "Could not parse 'remote' from OpenVPN config"
        [[ -n "$VPN_PORT" ]]   || err "Could not parse port from OpenVPN config"
        [[ -n "$VPN_PROTO" ]]  || VPN_PROTO="udp"

        info "VPN endpoint: $VPN_REMOTE:$VPN_PORT/$VPN_PROTO"

        rm -rf "$SECRETS_DIR"
        info "Removed $SECRETS_DIR (credentials now in /etc/openvpn/)"
    }

    # -- DNS update script (called by OpenVPN on tunnel up/down)
    setup_dns_update_script() {
        info "Writing OpenVPN DNS update script"

        cat > /etc/openvpn/update-dns.sh <<'DNSSCRIPT'
#!/usr/bin/env bash
# Called by OpenVPN via script-security 2 (up/down)
# Parses pushed DNS servers and reconfigures dnsmasq

DNSMASQ_VPN_CONF="/etc/dnsmasq.d/vpn-dns.conf"

case "$script_type" in
    up)
        dns_servers=()
        while IFS='=' read -r key value; do
            [[ "$key" =~ ^foreign_option_[0-9]+$ ]] || continue
            if [[ "$value" == dhcp-option\ DNS\ * ]]; then
                dns_servers+=("${value##* }")
            fi
        done < <(env | sort)

        if [[ ${#dns_servers[@]} -gt 0 ]]; then
            : > "$DNSMASQ_VPN_CONF"
            for srv in "${dns_servers[@]}"; do
                echo "server=${srv}" >> "$DNSMASQ_VPN_CONF"
            done
        else
            cat > "$DNSMASQ_VPN_CONF" <<EOF
server=103.86.96.100
server=103.86.99.100
EOF
        fi

        systemctl restart dnsmasq
        ;;
    down)
        rm -f "$DNSMASQ_VPN_CONF"
        systemctl restart dnsmasq
        ;;
esac
DNSSCRIPT

        chmod 0755 /etc/openvpn/update-dns.sh
        info "DNS update script written to /etc/openvpn/update-dns.sh"
    }

    # -- IP forwarding
    setup_forwarding() {
        info "Enabling IP forwarding"
        cat > /etc/sysctl.d/99-vpn-gateway.conf <<SYSCTL
net.ipv4.ip_forward = 1
SYSCTL
        sysctl -p /etc/sysctl.d/99-vpn-gateway.conf
    }

    # -- Kill switch + NAT (iptables)
    setup_firewall() {
        info "Configuring iptables kill switch and NAT"

        iptables -F
        iptables -t nat -F
        iptables -X

        iptables -P INPUT DROP
        iptables -P FORWARD DROP
        iptables -P OUTPUT ACCEPT

        # --- INPUT rules ---
        iptables -A INPUT -i lo -j ACCEPT
        iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
        iptables -A INPUT -i "$LAN_IFACE" -p tcp --dport 22 -j ACCEPT
        iptables -A INPUT -i "$LAN_IFACE" -p udp --dport 53 -j ACCEPT
        iptables -A INPUT -i "$LAN_IFACE" -p tcp --dport 53 -j ACCEPT
        iptables -A INPUT -i "$LAN_IFACE" -p icmp -j ACCEPT

        # --- FORWARD rules (kill switch) ---
        iptables -A FORWARD -i "$LAN_IFACE" -o "$VPN_IFACE" -j ACCEPT
        iptables -A FORWARD -i "$VPN_IFACE" -o "$LAN_IFACE" -m state --state ESTABLISHED,RELATED -j ACCEPT
        iptables -A FORWARD -i "$LAN_IFACE" -o "$LAN_IFACE" -j ACCEPT

        # --- NAT ---
        iptables -t nat -A POSTROUTING -o "$VPN_IFACE" -j MASQUERADE

        iptables-save > /etc/iptables/rules.v4

        info "Kill switch active: forwarded traffic only exits through $VPN_IFACE"
    }

    # -- dnsmasq base configuration
    setup_dnsmasq() {
        info "Configuring dnsmasq"

        # Stop dnsmasq if running with default config (may fail on wrong interface)
        systemctl stop dnsmasq 2>/dev/null || true

        [[ -f /etc/dnsmasq.conf ]] && mv /etc/dnsmasq.conf /etc/dnsmasq.conf.bak

        cat > /etc/dnsmasq.d/vpn-gateway.conf <<DNSMASQ
# Listen on LAN interface only
interface=$LAN_IFACE
bind-interfaces

# Do not read /etc/resolv.conf (we manage upstreams via vpn-dns.conf)
no-resolv

# Cache
cache-size=1000
DNSMASQ

        cat > /etc/dnsmasq.d/vpn-dns.conf <<DNS
server=103.86.96.100
server=103.86.99.100
DNS

        if ! systemctl restart dnsmasq; then
            journalctl -u dnsmasq --no-pager -n 20 >&2
            err "dnsmasq failed to start"
        fi
        systemctl enable dnsmasq
        info "dnsmasq configured: listening on $LAN_IFACE, forwarding to VPN DNS"
    }

    # -- Enable and start OpenVPN
    start_openvpn() {
        info "Enabling and starting OpenVPN"

        systemctl enable openvpn@client
        systemctl start openvpn@client

        info "Waiting for tunnel..."
        for i in $(seq 1 30); do
            if ip link show "$VPN_IFACE" &>/dev/null; then
                info "Tunnel $VPN_IFACE is up"
                return
            fi
            sleep 1
        done

        err "Tunnel $VPN_IFACE did not come up within 30 seconds. Check: journalctl -u openvpn@client"
    }

    # -- Verify
    verify() {
        info "Verifying VPN gateway"

        ip link show "$VPN_IFACE" &>/dev/null || err "Tunnel interface $VPN_IFACE not found"

        local vpn_ip
        vpn_ip=$(curl -s --max-time 10 https://ifconfig.me || true)
        if [[ -n "$vpn_ip" ]]; then
            info "External IP via VPN: $vpn_ip"
            if [[ "$vpn_ip" == "192.168."* ]]; then
                err "External IP is a LAN address, VPN tunnel may not be routing correctly"
            fi
        else
            info "Could not determine external IP (ifconfig.me unreachable), skipping IP check"
        fi

        local forward_rules
        forward_rules=$(iptables -L FORWARD -nv 2>/dev/null | grep -c "$VPN_IFACE" || true)
        [[ "$forward_rules" -ge 1 ]] || err "Kill switch rules not found in FORWARD chain"

        info "Verification passed"
    }

    # -- Run in-VM setup
    validate_inputs
    disable_resolved
    configure_apt_proxy
    install_packages
    setup_openvpn
    setup_dns_update_script
    setup_forwarding
    setup_firewall
    setup_dnsmasq
    start_openvpn
    verify

    cat <<EOF

================================================================
vpn-gateway setup complete (192.168.1.104).

VPN:         $VPN_REMOTE:$VPN_PORT/$VPN_PROTO
Kill switch: Active (FORWARD only through tun0, DROP if tunnel down)
DNS:         dnsmasq on 192.168.1.104:53 (forwarding to VPN DNS)
apt proxy:   ${APT_CACHE}:${APT_CACHE_PORT}

To use: set a device's default gateway and DNS to 192.168.1.104.
To stop: set the device's gateway and DNS back to 192.168.1.1.
================================================================
EOF
}

# ===================================================================
# Host-side: create VM and deploy (runs on the Proxmox host)
# ===================================================================

host_main() {
    source "$SCRIPT_DIR/lib/common.sh"
    [[ $EUID -eq 0 ]] || err "Run as root"

    local vmid="$VPN_GATEWAY_VMID"
    local hostname="vpn-gateway"
    local ip="$VPN_GATEWAY_IP"
    local deploy_only=0
    [[ "${1:-}" == "--deploy-only" ]] && deploy_only=1

    if [[ $deploy_only -eq 0 ]]; then
        if create_vm "$vmid" "$hostname" "$ip" 512 1 4 "$ROUTER_GW"; then
            qm start "$vmid"
            info "CREATED: VM $vmid ($hostname) at $ip"
            wait_for_vm "$vmid" "$ip"
        fi
    fi

    # Verify VM is running
    if ! qm status "$vmid" 2>/dev/null | grep -q "running"; then
        qm start "$vmid" 2>/dev/null || err "VM $vmid is not running and could not be started"
        wait_for_vm "$vmid" "$ip"
    fi

    # Push secrets into the VM via SCP
    if [[ -d "$SCRIPT_DIR/secrets" ]]; then
        # shellcheck disable=SC2086
        ssh $VM_SSH_OPTS "root@${ip}" "mkdir -p /root/secrets"
        for f in "$SCRIPT_DIR/secrets/"*; do
            [[ -f "$f" ]] || continue
            local fname
            fname=$(basename "$f")
            [[ "$fname" == ".gitignore" ]] && continue
            # shellcheck disable=SC2086
            scp $VM_SSH_OPTS "$f" "root@${ip}:/root/secrets/$fname"
            # shellcheck disable=SC2086
            ssh $VM_SSH_OPTS "root@${ip}" "chmod 0600 /root/secrets/$fname"
        done
    else
        err "secrets/ directory not found at $SCRIPT_DIR/secrets (need client.ovpn and auth.txt)"
    fi

    info "Deploying $hostname configuration (VM $vmid)"
    deploy_script_vm "$ip" "$SCRIPT_DIR/01-setup-vpn-gateway.sh"
}

# ===================================================================
# Dispatch: host-side vs in-VM
# ===================================================================

if [[ "${1:-}" == "--configure" ]]; then
    configure
else
    host_main "$@"
fi
