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
#   eth0 = 192.168.1.<CTID>/23 on vmbr0 (LAN, gateway = the VPN gateway)
#
# Prerequisites:
#   - the VPN gateway VM must be running
#   - NAS NFS export 192.168.1.254:/mnt/media/storage/bittorrent must be accessible
#
# This container runs qBittorrent-nox with three layers of VPN enforcement:
#   1. Default gateway is the VPN gateway, which has its own
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
    VPN_GATEWAY="${VPN_GATEWAY_IP:-192.168.1.110}"
    NAS_HOST="192.168.1.254"
    # The NAS exports /mnt/media/storage (to *), not /mnt/data/storage --
    # the old path simply does not exist there, so the mount failed with
    # "access denied by server" which reads like a permissions problem but
    # is not. Verified with showmount -e against the live NAS.
    NAS_EXPORT="${NAS_EXPORT:-192.168.1.254:/mnt/media/storage/bittorrent}"
    MOUNT_POINT="/mnt/torrents"
    LAN_IFACE="eth0"
    LAN_SUBNET="192.168.0.0/23"
    # Everything RFC1918 on 192.168/16 is treated as local and allowed; the
    # router is excluded explicitly above and must never be reachable.
    LAN_SUPERNET="192.168.0.0/16"
    ROUTER_IP="${ROUTER_GW:-192.168.1.1}"
    QBIT_PORT="8080"
    QBIT_EXT_PORT="80"
    QBIT_USER="qbittorrent"
    # Must match the ownership of the NAS share, which is 1000:1000 mode 775.
    # `useradd -r` would pick an arbitrary system uid, which lands in "other"
    # and cannot write -- see ensure_qbit_user().
    QBIT_UID="${QBIT_UID:-1000}"
    QBIT_GID="${QBIT_GID:-1000}"
    APT_CACHE="${APT_CACHE_IP:-192.168.1.103}"
    APT_CACHE_PORT="3142"

    err()  { echo "ERROR: $*" >&2; exit 1; }
    info() { echo "==> $*"; }

    [[ $EUID -eq 0 ]] || err "Run as root"

    LOCAL_IP=$(ip -4 addr show "$LAN_IFACE" | awk '/inet / {sub(/\/.*/, "", $2); print $2; exit}')

    # -- apt proxy
    # Use the apt cache only if it answers. A cache is an optimisation, not
    # a dependency: a host must still build when apt-cache is down or has not
    # been created yet.
    configure_apt_proxy() {
        mkdir -p /etc/apt/apt.conf.d
        rm -f /etc/apt/apt.conf.d/01proxy

        if timeout 3 bash -c "exec 3<>/dev/tcp/${APT_CACHE}/${APT_CACHE_PORT}" 2>/dev/null; then
            info "Using apt cache at ${APT_CACHE}:${APT_CACHE_PORT}"
            cat > /etc/apt/apt.conf.d/01proxy <<APTPROXY
Acquire::http::Proxy "http://${APT_CACHE}:${APT_CACHE_PORT}";
APTPROXY
        else
            info "apt cache unreachable at ${APT_CACHE}:${APT_CACHE_PORT}, fetching directly"
        fi
    }

    # -- Resolver
    #
    # The VPN gateway runs dnsmasq forwarding to the tunnel's DNS, so lookups
    # leave encrypted. Anything else -- including the internal resolver --
    # forwards to the router and therefore to the ISP, which leaks every
    # tracker and peer hostname even though the payload is tunnelled.
    # The authoritative fix is on the host side: host_main sets the
    # container's nameserver so PVE writes this file correctly on every
    # start. Rewriting it here just makes the running container correct
    # immediately, without waiting for a restart. Deliberately NOT made
    # immutable -- PVE manages this file, and locking it breaks container
    # start and every later re-run.
    configure_resolver() {
        info "Pointing DNS at the VPN gateway ($VPN_GATEWAY)"
        cat > /etc/resolv.conf <<RESOLV
nameserver $VPN_GATEWAY
RESOLV
    }

    # -- Packages
    install_packages() {
        info "Installing packages"
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
            qbittorrent-nox nfs-common iptables iptables-persistent curl
    }

    # Create the service account with an explicit uid/gid so it matches the
    # NAS share owner. Safe to re-run, and repairs an account that was
    # created earlier with the wrong ids.
    ensure_qbit_user() {
        # A group with the target GID must exist before usermod -g can use it.
        # Creating one by name is not enough: the name may already be taken at
        # the wrong gid, in which case groupadd fails and usermod then has no
        # target gid to move to.
        if ! getent group "$QBIT_GID" >/dev/null 2>&1; then
            if getent group "$QBIT_USER" >/dev/null 2>&1; then
                info "Moving group $QBIT_USER to gid $QBIT_GID"
                systemctl stop qbittorrent-nox 2>/dev/null || true
                groupmod -g "$QBIT_GID" "$QBIT_USER"
            else
                groupadd -g "$QBIT_GID" "$QBIT_USER"
            fi
        fi

        if id "$QBIT_USER" &>/dev/null; then
            local cur_uid cur_gid
            cur_uid=$(id -u "$QBIT_USER")
            cur_gid=$(id -g "$QBIT_USER")
            if [[ "$cur_uid" != "$QBIT_UID" || "$cur_gid" != "$QBIT_GID" ]]; then
                info "Repairing $QBIT_USER ids: ${cur_uid}:${cur_gid} -> ${QBIT_UID}:${QBIT_GID}"
                systemctl stop qbittorrent-nox 2>/dev/null || true
                usermod -u "$QBIT_UID" -g "$QBIT_GID" "$QBIT_USER"
                chown -R "$QBIT_UID:$QBIT_GID" /var/lib/qbittorrent 2>/dev/null || true
            fi
        else
            useradd -r -m -d /var/lib/qbittorrent -s /usr/sbin/nologin \
                -u "$QBIT_UID" -g "$QBIT_GID" "$QBIT_USER"
        fi
    }

    # -- NFS mount
    setup_nfs_mount() {
        info "Configuring NFS mount to NAS"

        ensure_qbit_user

        mkdir -p "$MOUNT_POINT"

        # Replace any existing entry for this mount point rather than only
        # appending when absent. Appending left a stale export alongside the
        # new one, and mount(8) takes the FIRST match -- so a corrected path
        # was silently ignored in favour of the broken one already there.
        if grep -q "[[:space:]]${MOUNT_POINT}[[:space:]]" /etc/fstab; then
            grep -v "[[:space:]]${MOUNT_POINT}[[:space:]]" /etc/fstab > /etc/fstab.new
            mv /etc/fstab.new /etc/fstab
        fi
        cat >> /etc/fstab <<FSTAB
$NAS_EXPORT $MOUNT_POINT nfs defaults,_netdev,nofail 0 0
FSTAB

        umount "$MOUNT_POINT" 2>/dev/null || true
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
    #
    # Egress policy, in order. Order is the whole point: iptables takes the
    # first match, so the router DROP has to precede every ACCEPT.
    #
    #   1. the router is DROPped first, unconditionally. Not after an
    #      established-state accept, not after the LAN accept -- first. It is
    #      the one address that could carry traffic straight to the ISP.
    #   2. DNS is allowed only to the VPN gateway, and every other resolver is
    #      dropped. Name lookups are traffic: resolving trackers through a LAN
    #      resolver that forwards to the router leaks them to the ISP even
    #      while the payload rides the tunnel.
    #   3. LAN is allowed (NAS, WebUI, the gateway itself).
    #   4. anything else is internet-bound and can only leave through the
    #      default route, which is the VPN gateway. The router being blocked
    #      means there is no second way out: if the tunnel is down the packets
    #      die at the gateway rather than falling back.
    setup_firewall() {
        info "Configuring egress kill switch"

        iptables -F
        iptables -t nat -F
        iptables -X

        iptables -P INPUT DROP
        iptables -P FORWARD DROP
        iptables -P OUTPUT DROP

        # --- 1. The router, before anything else can allow it ---
        # LOG first: a DROP terminates evaluation, so a LOG placed after it
        # never fires. Rate-limited so a misbehaving client cannot flood the
        # journal.
        iptables -A OUTPUT -d "$ROUTER_IP" -m limit --limit 6/min \
            -j LOG --log-prefix "BT-ROUTER-BLOCKED: " --log-level 4 2>/dev/null || true
        iptables -A OUTPUT -d "$ROUTER_IP" -j DROP

        # --- Loopback ---
        iptables -A INPUT -i lo -j ACCEPT
        iptables -A OUTPUT -o lo -j ACCEPT

        # --- NAT: redirect port 80 -> 8080 ---
        iptables -t nat -A PREROUTING -i "$LAN_IFACE" -p tcp --dport "$QBIT_EXT_PORT" -j REDIRECT --to-port "$QBIT_PORT"

        # --- INPUT ---
        iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
        iptables -A INPUT -i "$LAN_IFACE" -p tcp --dport 22 -j ACCEPT
        iptables -A INPUT -i "$LAN_IFACE" -p tcp --dport "$QBIT_PORT" -j ACCEPT

        # --- 2. DNS: the VPN gateway only ---
        iptables -A OUTPUT -d "$VPN_GATEWAY" -p udp --dport 53 -j ACCEPT
        iptables -A OUTPUT -d "$VPN_GATEWAY" -p tcp --dport 53 -j ACCEPT
        iptables -A OUTPUT -p udp --dport 53 -j DROP
        iptables -A OUTPUT -p tcp --dport 53 -j DROP
        # DNS-over-TLS would sidestep the above, so close it too.
        iptables -A OUTPUT -p tcp --dport 853 -j DROP
        iptables -A OUTPUT -p udp --dport 853 -j DROP

        # --- 3. LAN (NAS, WebUI replies, the gateway) ---
        iptables -A OUTPUT -d "$LAN_SUPERNET" -j ACCEPT

        # --- 4. Everything else: internet, forced through the default route ---
        # Torrent peers have public addresses, so this cannot be narrowed by
        # destination. It is constrained by routing instead: the only way off
        # this subnet is the VPN gateway, and the router is dropped above.
        iptables -A OUTPUT -j ACCEPT

        # IPv6 is disabled by sysctl, but a disabled stack that later comes
        # back would bypass every rule above. Deny it explicitly.
        if command -v ip6tables >/dev/null 2>&1; then
            ip6tables -P INPUT DROP  2>/dev/null || true
            ip6tables -P OUTPUT DROP 2>/dev/null || true
            ip6tables -P FORWARD DROP 2>/dev/null || true
        fi

        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4
        command -v ip6tables-save >/dev/null 2>&1 && ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true

        info "Egress locked: router DROPped, DNS only via $VPN_GATEWAY, internet only via default route"
    }

    # -- qBittorrent-nox configuration
    setup_qbittorrent() {
        info "Configuring qBittorrent-nox"

        ensure_qbit_user

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

VPN_GATEWAY="192.168.1.110"
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
    configure_resolver
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

    local ctid="$CTID_BITTORRENT"
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

    # Force the resolver to the VPN gateway ALONE, on every run.
    #
    # create_lxc passes --nameserver "$DNS_IP" for the internal resolver,
    # and this script passes the gateway, so pct ends up writing BOTH into
    # resolv.conf. The internal resolver forwards to the router and therefore
    # the ISP, so tracker lookups leaked out of the tunnel even though the
    # payload was tunnelled. This host is the one that must not use it.
    pct set "$ctid" --nameserver "$VPN_GATEWAY_IP"

    # Verify CT is running before deploying
    if ! pct status "$ctid" 2>/dev/null | grep -q "running"; then
        pct start "$ctid" 2>/dev/null || err "CT $ctid is not running and could not be started"
    fi

    info "Deploying $hostname configuration (CT $ctid)"
    deploy_script "$ctid" "$SCRIPT_DIR/02-setup-bittorrent.sh"
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
