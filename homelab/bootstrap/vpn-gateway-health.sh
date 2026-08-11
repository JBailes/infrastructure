#!/usr/bin/env bash
# Self-healing VPN gateway health check (smoothrouter).
#
# WHY THIS EXISTS
# OpenVPN can come up with a broken ovpn-dco data channel. Because the config
# uses persist-tun, tun0 and its routes stay in place and everything *looks*
# healthy while no data flows. The tunnel sat dead from Aug 07 until it was
# restarted by hand. So liveness is judged by bytes actually arriving through
# the tunnel, not by the interface or routes existing.
#
# PROBE CHOICE
# Read tun0's RX byte counter and require it to ADVANCE between runs. During
# the outage tun0 showed TX climbing and RX pinned at exactly 0 -- traffic
# going out, nothing coming back.
#
# Three probes that look reasonable and are all wrong here:
#   - pinging a public address (e.g. the provider's DNS): publicly routable,
#     so it answers via the home router with the tunnel down
#   - `ping -I tun0`: fails even on a healthy tunnel with a DCO device
#   - OpenVPN's status file ("Auth read bytes"): stays at 0 under DCO, because
#     the data channel is handled in the kernel and never counted in
#     userspace. An earlier version of this script used exactly that and so
#     restarted a perfectly healthy tunnel every time it ran.
#
# Note a freshly (re)started tunnel has near-zero counters, which is why the
# first run after a restart only requires a non-zero value, and why a stall
# has to be seen REPEATEDLY before acting.
#
# BACKOFF
# An earlier version of this script restarted OpenVPN every 60s on a false
# negative. NordVPN rate-limited the reconnects and started returning
# AUTH_FAILED. Hence the minimum restart interval and the auth-failure guard:
# a restart loop is worse than a down tunnel, because the kill switch already
# means a down tunnel leaks nothing.
#
# Also re-applies NAT and the kill switch: there is no iptables-persistent on
# this host, so re-applying on a boot timer is what makes those rules durable.

set -uo pipefail

TUN="tun0"
LAN_IFACE="eth0"
LAN_SUBNET="192.168.0.0/23"
SERVICE="routerd-vpn"
# Deliberately high. This watchdog has already caused more downtime than it
# prevented by reconnecting too eagerly, and the outage it exists for lasted
# four days -- ten minutes of detection latency costs nothing, a false
# reconnect costs a working tunnel and risks the provider's rate limiter.
STALL_LIMIT=10          # consecutive stalled checks (~10 min) before acting
STATE_FILE="/run/vpn-gateway-health.state"
STAMP_FILE="/run/vpn-gateway-health.lastrestart"
LOG="/var/log/vpn-gateway-health.log"
MIN_RESTART_INTERVAL=600   # seconds; never reconnect more often than this

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

apply_firewall() {
    iptables -t nat -C POSTROUTING -o "$TUN" -j MASQUERADE 2>/dev/null || {
        iptables -t nat -A POSTROUTING -o "$TUN" -j MASQUERADE
        log "re-added NAT MASQUERADE on $TUN"
    }

    if ! iptables -S FORWARD | head -1 | grep -q '^-P FORWARD DROP'; then
        iptables -P FORWARD DROP
        log "re-set FORWARD policy to DROP"
    fi

    iptables -C FORWARD -i "$LAN_IFACE" -o "$TUN" -j ACCEPT 2>/dev/null || \
        iptables -A FORWARD -i "$LAN_IFACE" -o "$TUN" -j ACCEPT
    iptables -C FORWARD -i "$TUN" -o "$LAN_IFACE" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
        iptables -A FORWARD -i "$TUN" -o "$LAN_IFACE" -m state --state ESTABLISHED,RELATED -j ACCEPT

    # LAN-to-LAN only. An unrestricted eth0->eth0 ACCEPT would let a client's
    # internet traffic route back out the home router unencrypted while the
    # tunnel is down -- exactly what the kill switch exists to prevent.
    iptables -C FORWARD -i "$LAN_IFACE" -o "$LAN_IFACE" -d "$LAN_SUBNET" -j ACCEPT 2>/dev/null || \
        iptables -A FORWARD -i "$LAN_IFACE" -o "$LAN_IFACE" -d "$LAN_SUBNET" -j ACCEPT
}

# Bytes received on the tunnel device, straight from the kernel. Valid under
# both DCO and the userspace data path.
rx_bytes() {
    awk -v ifc="$TUN:" '$1 == ifc {print $2; exit}' /proc/net/dev
}

# Deliberately push a little traffic through the tunnel and see whether RX
# moves. This is what separates "idle" from "dead": both look like a stalled
# counter, and only one of them warrants a reconnect.
#
# The target does not matter much, only that the request leaves through tun0 --
# which it does, because 0.0.0.0/1 routes there. Failures are ignored; the
# byte counter is the signal, not the exit status.
active_probe() {
    local before after
    before="$(rx_bytes)"
    timeout 5 curl -s --max-time 4 -o /dev/null http://1.1.1.1/ 2>/dev/null || true
    timeout 5 getent hosts one.one.one.one >/dev/null 2>&1 || true
    sleep 1
    after="$(rx_bytes)"
    [[ -n "$after" && -n "$before" && "$after" -gt "$before" ]]
}

# Healthy = interface present, tunnel routes installed, and RX advancing.
#
# A stall has to be seen STALL_LIMIT times in a row before it counts. A single
# quiet minute is not evidence of a dead tunnel, and restarting on one is how
# the previous version made things worse.
tunnel_healthy() {
    ip link show "$TUN" &>/dev/null                     || return 1
    ip route show | grep -q "0.0.0.0/1 via .* dev $TUN" || return 1

    local now prev stalls
    now="$(rx_bytes)"
    [[ -n "$now" && "$now" =~ ^[0-9]+$ ]] || return 1

    prev="$(cut -d' ' -f1 "$STATE_FILE" 2>/dev/null || echo "")"
    stalls="$(cut -d' ' -f2 "$STATE_FILE" 2>/dev/null || echo 0)"
    [[ "$stalls" =~ ^[0-9]+$ ]] || stalls=0

    # No baseline yet (first run, or just after a restart): accept and record.
    if [[ -z "$prev" || ! "$prev" =~ ^[0-9]+$ ]]; then
        echo "$now 0" > "$STATE_FILE"
        return 0
    fi

    if [[ "$now" -gt "$prev" ]]; then
        echo "$now 0" > "$STATE_FILE"
        return 0
    fi

    # RX did not move -- but an idle tunnel is not a dead one, and with no
    # client traffic it legitimately sits still. Generate a little traffic and
    # look again before counting this against it.
    if active_probe; then
        echo "$(rx_bytes) 0" > "$STATE_FILE"
        return 0
    fi

    stalls=$((stalls + 1))
    echo "$now $stalls" > "$STATE_FILE"
    (( stalls < STALL_LIMIT ))
}

recent_auth_failure() {
    journalctl -t openvpn --since "10 min ago" --no-pager 2>/dev/null \
        | grep -q "AUTH_FAILED"
}

restart_allowed() {
    local last now
    last="$(cat "$STAMP_FILE" 2>/dev/null || echo 0)"
    now="$(date +%s)"
    (( now - last >= MIN_RESTART_INTERVAL ))
}

apply_firewall

if tunnel_healthy; then
    exit 0
fi

# Credentials rejected: reconnecting cannot fix it and repeated attempts are
# what provoke the provider. Hold, and leave the kill switch doing its job.
if recent_auth_failure; then
    log "HOLD: provider returned AUTH_FAILED -- not reconnecting. Traffic stays blocked by the kill switch. Operator action needed."
    exit 0
fi

if ! restart_allowed; then
    log "HOLD: tunnel unhealthy but last restart was under ${MIN_RESTART_INTERVAL}s ago -- backing off."
    exit 0
fi

log "ALERT: tunnel unhealthy (tun0 RX stalled ${STALL_LIMIT}x or routes missing), restarting $SERVICE"
date +%s > "$STAMP_FILE"
rm -f "$STATE_FILE"
systemctl restart "$SERVICE"

# dnsmasq holds upstream sockets bound to the old tunnel and keeps using them
# after it is recreated, so DNS silently dies for every client behind this
# gateway even though the tunnel itself is fine. Restarting the tunnel without
# restarting dnsmasq left the bittorrent host with no name resolution twice.
if systemctl is-enabled --quiet dnsmasq 2>/dev/null || systemctl is-active --quiet dnsmasq 2>/dev/null; then
    systemctl restart dnsmasq && log "restarted dnsmasq (upstreams follow the new tunnel)"
fi

for _ in $(seq 1 8); do
    sleep 5
    if tunnel_healthy; then
        apply_firewall    # tun0 was recreated; rebind NAT to it
        log "Recovery: tunnel healthy again after restart"
        exit 0
    fi
done

log "ERROR: tunnel still unhealthy after restart -- kill switch keeps traffic blocked"
exit 0
