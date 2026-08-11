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
# Do NOT probe by pinging a public address (e.g. NordVPN's DNS): those are
# reachable through the home router too, so the probe passes with the tunnel
# down. Do NOT use `ping -I tun0` either -- source-binding to a DCO device
# fails even on a healthy tunnel. Instead read OpenVPN's own status file:
# "Auth read bytes" counts authenticated bytes received. It was pinned at 0
# for the whole outage, and with `ping 15` keepalives it always advances on a
# healthy tunnel, even with no client traffic.
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
STATUS_FILE_DEFAULT="/run/routerd-vpn.status"
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

# The tunnel is managed by routerd, which picks its own --status path.
# Read it off the running process so this never drifts from reality.
status_file() {
    local pid cmd f
    pid="$(pgrep -x openvpn | head -1)"
    if [[ -n "$pid" && -r "/proc/$pid/cmdline" ]]; then
        cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline")"
        f="$(sed -n 's/.*--status \([^ ]*\).*/\1/p' <<<"$cmd")"
        [[ -n "$f" && -r "$f" ]] && { echo "$f"; return; }
    fi
    echo "$STATUS_FILE_DEFAULT"
}

auth_read_bytes() {
    local f; f="$(status_file)"
    [[ -r "$f" ]] || { echo ""; return; }
    awk -F, '/^Auth read bytes/ {print $2; exit}' "$f" | tr -d '[:space:]'
}

# Healthy = interface present, tunnel routes installed, and authenticated
# bytes advancing since the previous run.
tunnel_healthy() {
    ip link show "$TUN" &>/dev/null                     || return 1
    ip route show | grep -q "0.0.0.0/1 via .* dev $TUN" || return 1

    local now prev
    now="$(auth_read_bytes)"
    [[ -n "$now" && "$now" =~ ^[0-9]+$ ]] || return 1
    [[ "$now" -gt 0 ]]                                  || return 1

    prev="$(cat "$STATE_FILE" 2>/dev/null || echo "")"
    echo "$now" > "$STATE_FILE"

    # First run after a restart has no baseline; a non-zero counter is enough.
    [[ -n "$prev" && "$prev" =~ ^[0-9]+$ ]] || return 0
    [[ "$now" -gt "$prev" ]]
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

log "ALERT: tunnel unhealthy (no authenticated bytes advancing), restarting $SERVICE"
date +%s > "$STAMP_FILE"
rm -f "$STATE_FILE"
systemctl restart "$SERVICE"

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
