#!/usr/bin/env bash
# 14-setup-vpn-gateway-health.sh -- Install the self-healing health check on the
# VPN gateway VM.
#
# Runs on: the Proxmox host (pushes to the gateway VM over SSH)
# Run order: Step 14 (any time after the VPN gateway exists)
#
# Usage:
#   ./14-setup-vpn-gateway-health.sh            # install and enable
#   ./14-setup-vpn-gateway-health.sh --status   # report current state, change nothing
#
# WHY THIS IS A SEPARATE SCRIPT
# The live gateway is VM 111 `smoothrouter`, a SmoothRouter appliance that runs
# OpenVPN under routerd-vpn.service. 01-setup-vpn-gateway.sh builds a plain
# Debian OpenVPN VM instead and would clobber it, so the health check is
# installed independently of however the gateway was provisioned. It only adds
# files under /usr/local/bin and /etc/systemd/system; it does not touch the
# appliance's own VPN config.
#
# WHAT IT FIXES
# OpenVPN can come up with a broken ovpn-dco data channel. Because the config
# sets persist-tun, tun0 and its routes stay in place while nothing flows, so
# the tunnel looks healthy and nothing recovers it -- one such outage ran from
# 2026-08-07 to 2026-08-11 unnoticed. The check judges liveness by
# authenticated bytes advancing in OpenVPN's status file.
#
# It also re-applies NAT and the kill switch on every run. There is no
# iptables-persistent on the gateway, so those rules do not survive a reboot;
# re-applying them on a boot timer is what makes them durable.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

PAYLOAD="$SCRIPT_DIR/vpn-gateway-health.sh"
REMOTE_BIN="/usr/local/bin/vpn-gateway-health.sh"
UNIT="vpn-gateway-health"

[[ $EUID -eq 0 ]] || err "Run as root"
[[ -f "$PAYLOAD" ]] || err "Missing payload: $PAYLOAD"

GW_SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no "root@${VPN_GATEWAY_IP}")

"${GW_SSH[@]}" true 2>/dev/null \
    || err "Cannot SSH to the VPN gateway at $VPN_GATEWAY_IP"

if [[ "${1:-}" == "--status" ]]; then
    "${GW_SSH[@]}" "
        echo 'timer:   '\$(systemctl is-active ${UNIT}.timer 2>/dev/null) \
             \$(systemctl is-enabled ${UNIT}.timer 2>/dev/null)
        echo 'tunnel:  '\$(ip link show tun0 >/dev/null 2>&1 && echo up || echo DOWN)
        echo 'forward: '\$(iptables -S FORWARD | head -1)
        echo '--- recent health log ---'
        tail -5 /var/log/vpn-gateway-health.log 2>/dev/null || echo '(none)'
    "
    exit 0
fi

info "Installing health check on the VPN gateway ($VPN_GATEWAY_IP)"
scp -o BatchMode=yes -o StrictHostKeyChecking=no -q "$PAYLOAD" "root@${VPN_GATEWAY_IP}:${REMOTE_BIN}"

"${GW_SSH[@]}" "
    set -e
    chmod 0755 '${REMOTE_BIN}'
    touch /var/log/vpn-gateway-health.log

    cat > /etc/systemd/system/${UNIT}.service <<'UNITFILE'
[Unit]
Description=VPN gateway health check and kill-switch enforcement
After=network.target

[Service]
Type=oneshot
ExecStart=${REMOTE_BIN}
UNITFILE

    cat > /etc/systemd/system/${UNIT}.timer <<'UNITFILE'
[Unit]
Description=Run VPN gateway health check every 60s

[Timer]
# Early on boot: the NAT and kill-switch rules are not persisted, so until
# this first run the FORWARD policy is whatever the kernel defaults to.
OnBootSec=5
OnUnitActiveSec=60
AccuracySec=5s

[Install]
WantedBy=timers.target
UNITFILE

    systemctl daemon-reload
    systemctl enable --now ${UNIT}.timer
"

info "Verifying"
"${GW_SSH[@]}" "
    ${REMOTE_BIN}
    echo 'timer:  '\$(systemctl is-active ${UNIT}.timer) \$(systemctl is-enabled ${UNIT}.timer)
    echo 'tunnel: '\$(ip link show tun0 >/dev/null 2>&1 && echo up || echo DOWN)
    echo 'nat:    '\$(iptables -t nat -S POSTROUTING | grep -c MASQUERADE) ' masquerade rule(s)'
    echo 'forward:'\$(iptables -S FORWARD | head -1)
"

cat <<EOF

================================================================
VPN gateway health check installed on $VPN_GATEWAY_IP.

Checks every 60s and at boot:
  - tun0 present and tunnel routes installed
  - authenticated bytes advancing in OpenVPN's status file
  - NAT MASQUERADE and the FORWARD kill switch re-applied

On failure it restarts routerd-vpn, with a 10 minute minimum between
reconnects. It will NOT retry after AUTH_FAILED: the provider rate-limits
reconnects, and a restart loop is worse than a down tunnel because the
kill switch already means a down tunnel leaks nothing.

  Log:    /var/log/vpn-gateway-health.log
  Status: ./14-setup-vpn-gateway-health.sh --status
================================================================
EOF
