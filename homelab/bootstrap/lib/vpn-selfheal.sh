#!/usr/bin/env bash
# vpn-selfheal.sh -- Install (or repair) self-healing on the VPN gateway
#
# Runs INSIDE the vpn-gateway VM. Invoked by 01-setup-vpn-gateway.sh during
# bootstrap, and runnable on its own against a live gateway to repair drift:
#
#   scp lib/vpn-selfheal.sh root@<gateway>:/root/ && ssh root@<gateway> /root/vpn-selfheal.sh
#
# This is the single definition of the gateway's self-healing. The bootstrap
# script pushes this file rather than carrying its own copy, so there is one
# place to change the escalation policy.
#
# Everything here is idempotent and safe to re-run. The only disruptive step
# is restarting openvpn@client when client.conf actually changed -- the kill
# switch stays in force throughout, so traffic blackholes rather than leaking.
#
# WHY (see also 01-setup-vpn-gateway.sh):
#
# Provider configs ship "ping-restart 0", disabling OpenVPN's reconnect on a
# dead peer, and "persist-tun" keeps tun0 present through a dead tunnel. The
# result is a tunnel that is completely wedged while the interface, the
# process and systemd all look healthy. Interface state is not service state,
# so the watchdog sends real packets out tun0.
#
# Layers: 1. systemd Restart=always     -- process dies
#         2. OpenVPN ping-restart 60    -- peer goes silent
#         3. this watchdog              -- tunnel up but no traffic passes
#         4. reboot                     -- restarts are not helping

set -euo pipefail

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

VPN_IFACE="${VPN_IFACE:-tun0}"
OVPN_CONF="/etc/openvpn/client.conf"

[[ $EUID -eq 0 ]] || err "Run as root"

# ---------------------------------------------------------------------------
# 1. OpenVPN must detect and recover from a dead tunnel on its own
# ---------------------------------------------------------------------------

harden_openvpn_config() {
    [[ -f "$OVPN_CONF" ]] || err "$OVPN_CONF not found -- is this the VPN gateway?"

    local before after
    before=$(sha256sum "$OVPN_CONF" | awk '{print $1}')

    set_directive() {
        local name="$1" value="$2"
        sed -i "/^${name}[[:space:]]/d; /^${name}\$/d" "$OVPN_CONF"
        echo "${name} ${value}" >> "$OVPN_CONF"
    }

    set_directive ping 15
    set_directive ping-restart 60
    set_directive resolv-retry infinite

    grep -qx 'persist-key' "$OVPN_CONF" || echo 'persist-key' >> "$OVPN_CONF"
    grep -qx 'persist-tun' "$OVPN_CONF" || echo 'persist-tun' >> "$OVPN_CONF"

    after=$(sha256sum "$OVPN_CONF" | awk '{print $1}')
    if [[ "$before" != "$after" ]]; then
        info "client.conf updated (ping-restart now 60) -- restart required"
        CONF_CHANGED=1
    else
        info "client.conf already hardened"
    fi
}

# ---------------------------------------------------------------------------
# 2. systemd should never give up on the tunnel or the resolver
# ---------------------------------------------------------------------------

install_restart_policy() {
    info "Applying restart policy to openvpn@client and dnsmasq"
    local unit
    for unit in openvpn@client dnsmasq; do
        mkdir -p "/etc/systemd/system/${unit}.service.d"
        cat > "/etc/systemd/system/${unit}.service.d/restart.conf" <<UNIT
# Managed by lib/vpn-selfheal.sh -- do not edit by hand.
[Unit]
# A rate-limited unit that gives up is an outage. Never stop trying.
StartLimitIntervalSec=0

[Service]
Restart=always
RestartSec=10
UNIT
    done
}

# ---------------------------------------------------------------------------
# 3. The watchdog
# ---------------------------------------------------------------------------

install_watchdog() {
    info "Installing the tunnel watchdog"
    cat > /usr/local/bin/vpn-healthcheck.sh <<'HEALTH'
#!/usr/bin/env bash
# vpn-healthcheck.sh -- verify traffic actually flows through the VPN tunnel
#
# Escalation (state in /run, cleared on boot):
#   FAIL_THRESHOLD consecutive failed probes    -> restart openvpn@client
#   RESTART_THRESHOLD restarts without recovery -> reboot the VM
#
# Exits 0 always: a failing watchdog must not mark the timer unit failed.

set -uo pipefail

VPN_IFACE="tun0"
STATE_DIR="/run/vpn-healthcheck"
FAIL_FILE="${STATE_DIR}/consecutive_failures"
RESTART_FILE="${STATE_DIR}/restarts_since_recovery"
METRIC_DIR="/var/lib/prometheus/node-exporter"
METRIC_FILE="${METRIC_DIR}/vpn_gateway.prom"

FAIL_THRESHOLD=3
RESTART_THRESHOLD=3
PROBE_TARGETS=(1.1.1.1 9.9.9.9)

# Never reboot a VM that just came up -- if the provider itself is down, no
# amount of rebooting helps and a boot loop makes it worse.
MIN_UPTIME_BEFORE_REBOOT=1200

mkdir -p "$STATE_DIR" "$METRIC_DIR"

read_counter()  { [[ -r "$1" ]] && cat "$1" 2>/dev/null || echo 0; }
write_counter() { echo "$2" > "$1"; }
log() { logger -t vpn-healthcheck "$*"; echo "vpn-healthcheck: $*"; }

# Healthy if ANY target answers *through the tunnel*. Two targets so one
# unreachable resolver does not trigger a needless restart. Deliberately not
# a check on whether tun0 exists: persist-tun keeps it alive when dead.
probe() {
    ip link show "$VPN_IFACE" &>/dev/null || return 1
    local target
    for target in "${PROBE_TARGETS[@]}"; do
        if ping -I "$VPN_IFACE" -c 1 -W 5 -n -q "$target" &>/dev/null; then
            return 0
        fi
    done
    return 1
}

write_metrics() {
    cat > "${METRIC_FILE}.tmp" <<EOF
# HELP vpn_gateway_tunnel_up Whether traffic currently flows through the VPN tunnel.
# TYPE vpn_gateway_tunnel_up gauge
vpn_gateway_tunnel_up ${1}
# HELP vpn_gateway_probe_failures Consecutive failed tunnel probes.
# TYPE vpn_gateway_probe_failures gauge
vpn_gateway_probe_failures ${2}
# HELP vpn_gateway_restarts_since_recovery OpenVPN restarts that have not yet restored the tunnel.
# TYPE vpn_gateway_restarts_since_recovery gauge
vpn_gateway_restarts_since_recovery ${3}
EOF
    mv "${METRIC_FILE}.tmp" "$METRIC_FILE"
}

fails=$(read_counter "$FAIL_FILE")
restarts=$(read_counter "$RESTART_FILE")

if probe; then
    if [[ "$fails" -gt 0 || "$restarts" -gt 0 ]]; then
        log "tunnel recovered after ${fails} failed probe(s), ${restarts} restart(s)"
    fi
    write_counter "$FAIL_FILE" 0
    write_counter "$RESTART_FILE" 0
    write_metrics 1 0 0
    exit 0
fi

fails=$((fails + 1))
write_counter "$FAIL_FILE" "$fails"
log "probe failed (${fails}/${FAIL_THRESHOLD})"

if [[ "$fails" -lt "$FAIL_THRESHOLD" ]]; then
    write_metrics 0 "$fails" "$restarts"
    exit 0
fi

if [[ "$restarts" -ge "$RESTART_THRESHOLD" ]]; then
    uptime_now=$(awk '{print int($1)}' /proc/uptime)
    if [[ "$uptime_now" -lt "$MIN_UPTIME_BEFORE_REBOOT" ]]; then
        log "would reboot, but uptime is ${uptime_now}s -- provider likely down, holding off"
        write_metrics 0 "$fails" "$restarts"
        exit 0
    fi
    log "FATAL: ${restarts} restarts did not restore the tunnel -- rebooting"
    write_metrics 0 "$fails" "$restarts"
    systemctl reboot
    exit 0
fi

restarts=$((restarts + 1))
write_counter "$RESTART_FILE" "$restarts"
write_counter "$FAIL_FILE" 0
log "restarting openvpn@client (attempt ${restarts}/${RESTART_THRESHOLD})"
systemctl restart openvpn@client
write_metrics 0 0 "$restarts"
exit 0
HEALTH
    chmod 0755 /usr/local/bin/vpn-healthcheck.sh

    cat > /etc/systemd/system/vpn-healthcheck.service <<'SVC'
# Managed by lib/vpn-selfheal.sh
[Unit]
Description=VPN tunnel health check and self-heal
After=openvpn@client.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/vpn-healthcheck.sh
SVC

    cat > /etc/systemd/system/vpn-healthcheck.timer <<'TIMER'
# Managed by lib/vpn-selfheal.sh
[Unit]
Description=Run the VPN tunnel health check every 30s

[Timer]
OnBootSec=60
OnUnitActiveSec=30
AccuracySec=5s

[Install]
WantedBy=timers.target
TIMER
}

# ---------------------------------------------------------------------------
# 4. Expose watchdog state to Prometheus
# ---------------------------------------------------------------------------

install_metrics() {
    if ! command -v prometheus-node-exporter &>/dev/null \
        && [[ ! -x /usr/bin/prometheus-node-exporter ]]; then
        info "Installing prometheus-node-exporter"
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
            prometheus-node-exporter iputils-ping >/dev/null
    fi

    mkdir -p /var/lib/prometheus/node-exporter
    cat > /etc/default/prometheus-node-exporter <<'NODEEXP'
# Managed by lib/vpn-selfheal.sh
ARGS="--collector.textfile.directory=/var/lib/prometheus/node-exporter"
NODEEXP

    # Let obs scrape it. The gateway's INPUT policy is DROP.
    local lan_iface
    lan_iface=$(ip -4 route show default | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    if [[ -n "$lan_iface" ]] && ! iptables -C INPUT -i "$lan_iface" -p tcp --dport 9100 -j ACCEPT 2>/dev/null; then
        iptables -A INPUT -i "$lan_iface" -p tcp --dport 9100 -j ACCEPT
        [[ -d /etc/iptables ]] && iptables-save > /etc/iptables/rules.v4
        info "Opened :9100 on ${lan_iface} for Prometheus"
    fi
}

# ---------------------------------------------------------------------------
# 5. Arm and verify
# ---------------------------------------------------------------------------

arm_and_verify() {
    systemctl daemon-reload
    systemctl enable --now prometheus-node-exporter >/dev/null 2>&1 || true
    systemctl restart prometheus-node-exporter || info "WARNING: node-exporter did not start"
    systemctl enable --now vpn-healthcheck.timer

    if [[ "${CONF_CHANGED:-0}" == "1" ]]; then
        info "Restarting openvpn@client to pick up ping-restart"
        systemctl restart openvpn@client
        sleep 15
    fi

    systemctl is-active --quiet vpn-healthcheck.timer \
        || err "vpn-healthcheck.timer is not active -- self-healing is NOT armed"
    systemctl show openvpn@client -p Restart | grep -q 'Restart=always' \
        || err "openvpn@client is not Restart=always -- self-healing is NOT armed"
    grep -qx 'ping-restart 60' "$OVPN_CONF" \
        || err "ping-restart is not set -- OpenVPN will not reconnect on a dead tunnel"

    # Prove the probe works end to end rather than assuming it does.
    /usr/local/bin/vpn-healthcheck.sh >/dev/null 2>&1 || true
    if grep -qx 'vpn_gateway_tunnel_up 1' /var/lib/prometheus/node-exporter/vpn_gateway.prom 2>/dev/null; then
        info "Watchdog probe succeeded: traffic is flowing through ${VPN_IFACE}"
    else
        echo "WARNING: watchdog did not report a healthy tunnel. Check: journalctl -t vpn-healthcheck" >&2
    fi
}

harden_openvpn_config
install_restart_policy
install_watchdog
install_metrics
arm_and_verify

info "VPN self-healing armed (probe every 30s; 3 failures -> restart, 3 failed restarts -> reboot)"
