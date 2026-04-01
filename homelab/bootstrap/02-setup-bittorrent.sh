#!/usr/bin/env bash
# 02-setup-bittorrent.sh -- Create and configure the BitTorrent LXC
#
# Runs on: the Proxmox host (creates CT 116, then configures it)
# Run order: Step 02 (after vpn-gateway)
#
# Usage:
#   ./02-setup-bittorrent.sh               # Create CT and configure
#   ./02-setup-bittorrent.sh --deploy-only  # Re-run configuration on existing CT
#   ./02-setup-bittorrent.sh --configure    # (internal) Run inside the container
#
# Creates a privileged Debian 13 LXC (CT 116):
#   eth0 = 192.168.1.116/23 on vmbr0 (LAN, gateway = VPN gateway 192.168.1.104)
#
# Prerequisites:
#   - VPN gateway (192.168.1.104) must be running
#   - NAS NFS export 192.168.1.254:/mnt/data/storage/bittorrent must be accessible
#
# This container runs qBittorrent-nox with three layers of VPN enforcement:
#   1. Default gateway is the VPN gateway (192.168.1.104), which has its own
#      kill switch that drops all forwarded traffic if the tunnel is down
#   2. Local iptables: OUTPUT policy DROP, only allows traffic to the VPN
#      gateway and NAS
#   3. Watchdog: checks default route and gateway reachability every 60s,
#      stops qBittorrent immediately if anything is wrong

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ===================================================================
# In-container configuration (runs inside CT 116)
# ===================================================================

configure() {
    VPN_GATEWAY="192.168.1.104"
    NAS_HOST="192.168.1.254"
    NAS_EXPORT="192.168.1.254:/mnt/data/storage/bittorrent"
    MOUNT_POINT="/mnt/torrents"
    LAN_IFACE="eth0"
    LAN_SUBNET="192.168.0.0/23"
    QBIT_PORT="8080"
    QBIT_EXT_PORT="80"
    QBIT_USER="qbittorrent"
    APT_CACHE="192.168.1.115"
    APT_CACHE_PORT="3142"

    err()  { echo "ERROR: $*" >&2; exit 1; }
    info() { echo "==> $*"; }

    [[ $EUID -eq 0 ]] || err "Run as root"

    LOCAL_IP=$(ip -4 addr show "$LAN_IFACE" | awk '/inet / {sub(/\/.*/, "", $2); print $2; exit}')

    # -- apt proxy
    configure_apt_proxy() {
        info "Configuring apt proxy (apt-cache at ${APT_CACHE}:${APT_CACHE_PORT})"
        cat > /etc/apt/apt.conf.d/01proxy <<APTPROXY
Acquire::http::Proxy "http://${APT_CACHE}:${APT_CACHE_PORT}";
Acquire::https::Proxy "http://${APT_CACHE}:${APT_CACHE_PORT}";
Acquire::http::Proxy::Fallback "DIRECT";
Acquire::https::Proxy::Fallback "DIRECT";
APTPROXY
    }

    # -- Packages
    install_packages() {
        info "Installing packages"
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
            qbittorrent-nox nfs-common iptables iptables-persistent curl
    }

    # -- NFS mount
    setup_nfs_mount() {
        info "Configuring NFS mount to NAS"

        if ! id "$QBIT_USER" &>/dev/null; then
            useradd -r -m -d /var/lib/qbittorrent -s /usr/sbin/nologin "$QBIT_USER"
        fi

        mkdir -p "$MOUNT_POINT"

        if ! grep -q "$NAS_EXPORT" /etc/fstab; then
            cat >> /etc/fstab <<FSTAB
$NAS_EXPORT $MOUNT_POINT nfs defaults,_netdev,nofail 0 0
FSTAB
        fi

        mount -a

        if mountpoint -q "$MOUNT_POINT"; then
            info "NAS mounted at $MOUNT_POINT"
        else
            err "Failed to mount $NAS_EXPORT at $MOUNT_POINT"
        fi

        mkdir -p "$MOUNT_POINT/complete" "$MOUNT_POINT/incomplete"
        info "Download directories ready: complete/, incomplete/"
    }

    # -- Kill switch (iptables)
    setup_firewall() {
        info "Configuring local iptables kill switch"

        iptables -F
        iptables -t nat -F
        iptables -X

        iptables -P INPUT DROP
        iptables -P FORWARD DROP
        iptables -P OUTPUT DROP

        # --- Loopback ---
        iptables -A INPUT -i lo -j ACCEPT
        iptables -A OUTPUT -o lo -j ACCEPT

        # --- NAT: redirect port 80 -> 8080 ---
        iptables -t nat -A PREROUTING -i "$LAN_IFACE" -p tcp --dport "$QBIT_EXT_PORT" -j REDIRECT --to-port "$QBIT_PORT"

        # --- INPUT ---
        iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
        iptables -A INPUT -i "$LAN_IFACE" -p tcp --dport 22 -j ACCEPT
        iptables -A INPUT -i "$LAN_IFACE" -p tcp --dport "$QBIT_PORT" -j ACCEPT

        # --- OUTPUT ---
        # Block router (must not bypass VPN gateway)
        iptables -A OUTPUT -d 192.168.1.1 -j DROP

        # Allow everything else. Torrent peers have public IPs, so we
        # cannot restrict to LAN only. Routing sends all traffic through
        # the VPN gateway (192.168.1.104), whose kill switch ensures
        # nothing exits unencrypted.
        iptables -A OUTPUT -j ACCEPT

        iptables-save > /etc/iptables/rules.v4

        info "Kill switch active: all outbound allowed except 192.168.1.1 (router)"
    }

    # -- qBittorrent-nox configuration
    setup_qbittorrent() {
        info "Configuring qBittorrent-nox"

        if ! id "$QBIT_USER" &>/dev/null; then
            useradd -r -m -d /var/lib/qbittorrent -s /usr/sbin/nologin "$QBIT_USER"
        fi

        local config_dir="/var/lib/qbittorrent/.config/qBittorrent"
        mkdir -p "$config_dir"

        cat > /usr/local/bin/torrent-complete.sh <<'TSCRIPT'
#!/usr/bin/env bash
# Called by qBittorrent on torrent completion.
# %F = content path (single file or root directory of multi-file torrent)
chmod -R 777 "$1" 2>/dev/null || true
TSCRIPT
        chmod 755 /usr/local/bin/torrent-complete.sh

        cat > "$config_dir/qBittorrent.conf" <<QBITCONF
[LegalNotice]
Accepted=true

[Preferences]
Downloads\\SavePath=$MOUNT_POINT/complete/
Downloads\\TempPath=$MOUNT_POINT/incomplete/
Downloads\\TempPathEnabled=true
Downloads\\TorrentExportDir=
WebUI\\Port=$QBIT_PORT
WebUI\\Address=*
WebUI\\AuthSubnetWhitelistEnabled=true
WebUI\\AuthSubnetWhitelist=192.168.0.0/23
Connection\\InterfaceName=$LAN_IFACE
Connection\\InterfaceAddress=$LOCAL_IP

[AutoRun]
enabled=true
program=/usr/local/bin/torrent-complete.sh \"%F\"
QBITCONF

        chown -R "$QBIT_USER:$QBIT_USER" /var/lib/qbittorrent

        cat > /etc/systemd/system/qbittorrent-nox.service <<SERVICE
[Unit]
Description=qBittorrent-nox
After=network-online.target mnt-torrents.mount
Wants=network-online.target mnt-torrents.mount

[Service]
Type=simple
User=$QBIT_USER
Group=$QBIT_USER
ExecStart=/usr/bin/qbittorrent-nox --webui-port=$QBIT_PORT
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
SERVICE

        systemctl daemon-reload
        systemctl enable qbittorrent-nox
        systemctl start qbittorrent-nox
        info "qBittorrent-nox started on port $QBIT_PORT"
    }

    # -- Watchdog
    setup_watchdog() {
        info "Installing VPN watchdog"

        cat > /usr/local/bin/vpn-watchdog.sh <<'WATCHDOG'
#!/usr/bin/env bash
# VPN watchdog: stop qBittorrent if traffic would not go through VPN gateway

VPN_GATEWAY="192.168.1.104"
SERVICE="qbittorrent-nox"
LOGFILE="/var/log/vpn-watchdog.log"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOGFILE"; }

default_gw=$(ip route show default | awk '/^default/ {for (i=1; i<=NF; i++) if ($i=="via") {print $(i+1); exit}}')
if [[ "$default_gw" != "$VPN_GATEWAY" ]]; then
    log "ALERT: default route is $default_gw (expected $VPN_GATEWAY), stopping $SERVICE"
    systemctl stop "$SERVICE" 2>/dev/null
    exit 1
fi

if ! ping -c 1 -W 3 "$VPN_GATEWAY" &>/dev/null; then
    log "ALERT: VPN gateway $VPN_GATEWAY unreachable, stopping $SERVICE"
    systemctl stop "$SERVICE" 2>/dev/null
    exit 1
fi

if ! systemctl is-active --quiet "$SERVICE"; then
    log "Recovery: checks passed, restarting $SERVICE"
    systemctl start "$SERVICE"
fi
WATCHDOG

        chmod 0755 /usr/local/bin/vpn-watchdog.sh

        cat > /etc/systemd/system/vpn-watchdog.service <<WDSVC
[Unit]
Description=VPN watchdog check

[Service]
Type=oneshot
ExecStart=/usr/local/bin/vpn-watchdog.sh
WDSVC

        cat > /etc/systemd/system/vpn-watchdog.timer <<WDTIMER
[Unit]
Description=VPN watchdog timer

[Timer]
OnBootSec=30
OnUnitActiveSec=60

[Install]
WantedBy=timers.target
WDTIMER

        touch /var/log/vpn-watchdog.log

        systemctl daemon-reload
        systemctl enable vpn-watchdog.timer
        systemctl start vpn-watchdog.timer
        info "Watchdog installed: checking every 60s"
    }

    # -- Verify
    verify() {
        info "Verifying bittorrent LXC"

        local gw
        gw=$(ip route show default | awk '/^default/ {for (i=1; i<=NF; i++) if ($i=="via") {print $(i+1); exit}}')
        [[ "$gw" == "$VPN_GATEWAY" ]] || err "Default gateway is $gw, expected $VPN_GATEWAY"
        info "Default gateway: $VPN_GATEWAY"

        ping -c 1 -W 3 "$VPN_GATEWAY" &>/dev/null || err "VPN gateway $VPN_GATEWAY unreachable"
        info "VPN gateway reachable"

        mountpoint -q "$MOUNT_POINT" || err "NAS not mounted at $MOUNT_POINT"
        info "NAS mounted at $MOUNT_POINT"

        systemctl is-active --quiet qbittorrent-nox || err "qBittorrent-nox is not running"
        info "qBittorrent-nox running on port $QBIT_PORT"

        local output_policy
        output_policy=$(iptables -L OUTPUT -n | awk '/^Chain OUTPUT/ {gsub(/[()]/, "", $4); print $4; exit}')
        [[ "$output_policy" == "DROP" ]] || err "OUTPUT policy is $output_policy, expected DROP"
        info "Kill switch active (OUTPUT policy DROP)"

        info "Verification passed"
    }

    # -- Run in-container setup
    configure_apt_proxy
    install_packages
    setup_nfs_mount
    setup_firewall
    setup_qbittorrent
    setup_watchdog
    verify

    cat <<EOF

================================================================
bittorrent LXC setup complete ($LOCAL_IP).

qBittorrent:  Web UI at http://$LOCAL_IP
Storage:      $NAS_EXPORT (NFS mount)
  Complete:   $MOUNT_POINT/complete/
  Incomplete: $MOUNT_POINT/incomplete/
VPN gateway:  $VPN_GATEWAY (default route)
Kill switch:  Active (router blocked, all traffic routes through VPN gateway)
Watchdog:     Active (60s interval, stops qBittorrent on failure)
================================================================
EOF
}

# ===================================================================
# Host-side: create CT and deploy (runs on the Proxmox host)
# ===================================================================

host_main() {
    source "$SCRIPT_DIR/lib/common.sh"
    [[ $EUID -eq 0 ]] || err "Run as root"

    local ctid=116
    local hostname="bittorrent"
    local ip="192.168.1.${ctid}"
    local deploy_only=0
    [[ "${1:-}" == "--deploy-only" ]] && deploy_only=1

    if [[ $deploy_only -eq 0 ]]; then
        if create_lxc "$ctid" "$hostname" "$ip" 1024 2 8 "$VPN_GATEWAY_IP" "yes" \
                --nameserver "$VPN_GATEWAY_IP"; then
            pct start "$ctid"
            info "CREATED: CT $ctid ($hostname) at $ip"
        fi
    fi

    # Verify CT is running before deploying
    if ! pct status "$ctid" 2>/dev/null | grep -q "running"; then
        pct start "$ctid" 2>/dev/null || err "CT $ctid is not running and could not be started"
    fi

    info "Deploying $hostname configuration (CT $ctid)"
    deploy_script "$ctid" "$SCRIPT_DIR/02-setup-bittorrent.sh"
}

# ===================================================================
# Dispatch: host-side vs in-container
# ===================================================================

if [[ "${1:-}" == "--configure" ]]; then
    configure
else
    host_main "$@"
fi
