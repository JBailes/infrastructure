#!/usr/bin/env bash
# 07-setup-selfheal.sh -- Make the ACK! hosts self-healing and self-fixable
#
# Runs on: the Proxmox host (pushes itself into each ACK container)
# Run order: Step 07 (last, after all ACK hosts exist and are configured)
#
# Usage:
#   ./07-setup-selfheal.sh                 # Apply to every ACK host
#   ./07-setup-selfheal.sh --host acktng   # Apply to one host
#   ./07-setup-selfheal.sh --repair        # Repair pass: also fix the CTs
#                                          # themselves (onboot, stopped CTs,
#                                          # disabled units) before applying
#   ./07-setup-selfheal.sh --configure     # (internal) Run inside a container
#
# WHY THIS EXISTS
#
# The ACK services were deployed with `Restart=on-failure`, which has two
# failure modes that produce silent, permanent outages:
#
#   1. `on-failure` ignores a clean exit. A MUD that shuts itself down with
#      status 0 -- which the legacy ACK binaries do on several internal
#      errors -- is never restarted.
#   2. systemd's default start rate limit (5 starts / 10s) is still in force.
#      A service that crash-loops briefly trips the limit and systemd then
#      refuses to start it again *at all* until an operator intervenes. The
#      recovery mechanism is exactly what takes the service down for good.
#
# On top of that, a MUD process can be alive but wedged -- accepting no
# connections while systemd sees a perfectly healthy unit. Process liveness
# is not service liveness, so this installs a port probe.
#
# SELF-FIXABLE
#
# Every action here is idempotent and re-runnable. `--repair` is the "put it
# back the way it should be" button: it walks all ACK containers, restarts
# stopped ones, re-enables disabled units, re-asserts onboot, and re-applies
# the self-healing config. Nothing is destructive.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Host -> systemd unit and the TCP port that proves it is really serving.
# Format: hostname|ctid|unit|probe_port
#
# Ports must match the game ports in pve-setup-ack.sh (see the mud_hosts list
# in its verify step). acktng is the odd one out: it serves on 8890 directly
# rather than the 4000 the legacy MUDs use. A wrong port here is worse than no
# watchdog at all -- it restarts a perfectly healthy service on a loop.
ACK_HOSTS=(
    "ack-gateway|240|dnsmasq|53"
    "acktng|241|mud|8890"
    "ack431|242|mud|4000"
    "ack42|243|mud|4000"
    "ack41|244|mud|4000"
    "assault30|245|mud|4000"
    "ackfuss|250|mud|4000"
    "ack-db|246|postgresql|5432"
    "ack-web|247|ack-web|5000"
    "tng-ai|248|tng-ai|8000"
    "tngdb|249|tngdb|8000"
)

# ===================================================================
# In-container configuration
# ===================================================================

configure() {
    err()  { echo "ERROR: $*" >&2; exit 1; }
    info() { echo "==> $*"; }

    local unit="${SELFHEAL_UNIT:?SELFHEAL_UNIT not set}"
    local port="${SELFHEAL_PORT:?SELFHEAL_PORT not set}"

    [[ $EUID -eq 0 ]] || err "Run as root"

    # A unit that was never deployed is not an error -- some hosts are
    # partially provisioned. Report and leave the host alone.
    if [[ ! -f "/etc/systemd/system/${unit}.service" ]] \
        && ! systemctl cat "${unit}.service" &>/dev/null; then
        info "SKIP: ${unit}.service is not installed on this host"
        return 0
    fi

    # -- 1. Always restart, and never let systemd give up permanently
    info "Applying restart policy to ${unit}.service"
    mkdir -p "/etc/systemd/system/${unit}.service.d"
    cat > "/etc/systemd/system/${unit}.service.d/selfheal.conf" <<UNIT
# Managed by 07-setup-selfheal.sh -- do not edit by hand.
[Unit]
# Without this, a brief crash-loop trips systemd's start limit and the
# service stays down until someone logs in. An outage caused by the
# recovery mechanism is worse than the original crash.
StartLimitIntervalSec=0

[Service]
# on-failure ignores clean exits; the legacy ACK binaries exit 0 on some
# internal errors. always covers both.
Restart=always
RestartSec=10
UNIT

    # -- 2. Liveness probe: the port must actually accept connections
    info "Installing health probe for ${unit} on :${port}"
    cat > /usr/local/bin/ack-healthcheck.sh <<'HEALTH'
#!/usr/bin/env bash
# ack-healthcheck.sh -- restart a wedged ACK service
#
# systemd only knows whether the process exists. This checks whether the
# service still answers on its port, which is what actually matters to a
# player connecting to the MUD.
#
# Escalation: FAIL_THRESHOLD failed probes -> restart the unit.
#             RESTART_THRESHOLD failed restarts -> reboot the container.
# Always exits 0 so the timer unit never enters a failed state.

set -uo pipefail

UNIT="${1:?usage: ack-healthcheck.sh <unit> <port>}"
PORT="${2:?usage: ack-healthcheck.sh <unit> <port>}"

STATE_DIR="/run/ack-healthcheck"
FAIL_FILE="${STATE_DIR}/${UNIT}.failures"
RESTART_FILE="${STATE_DIR}/${UNIT}.restarts"

FAIL_THRESHOLD=3
RESTART_THRESHOLD=3
MIN_UPTIME_BEFORE_REBOOT=900

mkdir -p "$STATE_DIR"

log() { logger -t ack-healthcheck "[$UNIT] $*"; echo "ack-healthcheck [$UNIT]: $*"; }
read_counter()  { [[ -r "$1" ]] && cat "$1" 2>/dev/null || echo 0; }
write_counter() { echo "$2" > "$1"; }

# Only probe if the unit is supposed to be running. A deliberately stopped
# service must not be force-started by the watchdog.
if ! systemctl is-enabled --quiet "${UNIT}.service" 2>/dev/null; then
    exit 0
fi

probe() {
    # bash's /dev/tcp needs no extra packages in these minimal containers.
    timeout 5 bash -c "exec 3<>/dev/tcp/127.0.0.1/${PORT}" 2>/dev/null
}

fails=$(read_counter "$FAIL_FILE")
restarts=$(read_counter "$RESTART_FILE")

if probe; then
    if [[ "$fails" -gt 0 || "$restarts" -gt 0 ]]; then
        log "recovered after ${fails} failed probe(s), ${restarts} restart(s)"
    fi
    write_counter "$FAIL_FILE" 0
    write_counter "$RESTART_FILE" 0
    exit 0
fi

fails=$((fails + 1))
write_counter "$FAIL_FILE" "$fails"
log "port ${PORT} not answering (${fails}/${FAIL_THRESHOLD})"

if [[ "$fails" -lt "$FAIL_THRESHOLD" ]]; then
    exit 0
fi

if [[ "$restarts" -ge "$RESTART_THRESHOLD" ]]; then
    uptime_now=$(awk '{print int($1)}' /proc/uptime)
    if [[ "$uptime_now" -lt "$MIN_UPTIME_BEFORE_REBOOT" ]]; then
        log "would reboot, but container uptime is ${uptime_now}s -- holding off to avoid a boot loop"
        exit 0
    fi
    log "FATAL: ${restarts} restarts did not recover ${UNIT} -- rebooting container"
    systemctl reboot
    exit 0
fi

restarts=$((restarts + 1))
write_counter "$RESTART_FILE" "$restarts"
write_counter "$FAIL_FILE" 0
log "restarting ${UNIT}.service (attempt ${restarts}/${RESTART_THRESHOLD})"
systemctl restart "${UNIT}.service"
exit 0
HEALTH
    chmod 0755 /usr/local/bin/ack-healthcheck.sh

    cat > /etc/systemd/system/ack-healthcheck.service <<SVC
# Managed by 07-setup-selfheal.sh
[Unit]
Description=ACK service health check and self-heal
After=${unit}.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/ack-healthcheck.sh ${unit} ${port}
SVC

    cat > /etc/systemd/system/ack-healthcheck.timer <<'TIMER'
# Managed by 07-setup-selfheal.sh
[Unit]
Description=Run the ACK service health check every 60s

[Timer]
OnBootSec=120
OnUnitActiveSec=60
AccuracySec=10s

[Install]
WantedBy=timers.target
TIMER

    # -- 3. Arm everything
    systemctl daemon-reload
    systemctl enable "${unit}.service" >/dev/null 2>&1 || true
    systemctl enable --now ack-healthcheck.timer

    # -- 4. Self-fix: if the service should be running but is not, start it
    if ! systemctl is-active --quiet "${unit}.service"; then
        info "REPAIR: ${unit}.service was not running -- starting it"
        systemctl start "${unit}.service" || info "WARNING: ${unit}.service failed to start"
    fi

    # -- 5. Verify rather than assume
    systemctl is-active --quiet ack-healthcheck.timer \
        || err "ack-healthcheck.timer is not active -- self-healing is NOT armed"

    systemctl show "${unit}" -p Restart | grep -q 'Restart=always' \
        || err "${unit}.service is not Restart=always -- self-healing is NOT armed"

    info "Self-healing armed for ${unit}.service (probe :${port} every 60s)"
}

# ===================================================================
# Host-side
# ===================================================================

host_main() {
    err()  { echo "ERROR: $*" >&2; exit 1; }
    info() { echo "==> $*"; }
    step() { echo "--- $*"; }

    [[ $EUID -eq 0 ]] || err "Run as root"

    local only_host="" repair=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --host)   only_host="${2:?--host needs a hostname}"; shift 2 ;;
            --repair) repair=1; shift ;;
            *)        err "Unknown argument: $1" ;;
        esac
    done

    local applied=0 skipped=0 failed=0

    for entry in "${ACK_HOSTS[@]}"; do
        IFS='|' read -r name ctid unit port <<< "$entry"
        [[ -n "$only_host" && "$only_host" != "$name" ]] && continue

        if ! pct status "$ctid" &>/dev/null; then
            step "SKIP: CT $ctid ($name) does not exist"
            skipped=$((skipped + 1))
            continue
        fi

        if [[ $repair -eq 1 ]]; then
            # Survive a Proxmox host reboot.
            if [[ "$(pct config "$ctid" | awk -F': ' '/^onboot:/{print $2}')" != "1" ]]; then
                step "REPAIR: setting onboot=1 on CT $ctid ($name)"
                pct set "$ctid" --onboot 1
            fi
            if ! pct status "$ctid" | grep -q running; then
                step "REPAIR: starting stopped CT $ctid ($name)"
                pct start "$ctid" || { echo "WARN: could not start CT $ctid" >&2; failed=$((failed + 1)); continue; }
                sleep 5
            fi
        fi

        if ! pct status "$ctid" | grep -q running; then
            step "SKIP: CT $ctid ($name) is not running (use --repair to start it)"
            skipped=$((skipped + 1))
            continue
        fi

        step "Applying self-healing to $name (CT $ctid, ${unit}.service :${port})"
        pct push "$ctid" "$SCRIPT_DIR/07-setup-selfheal.sh" /root/07-setup-selfheal.sh --perms 0755
        if pct exec "$ctid" -- bash -c \
            "SELFHEAL_UNIT=${unit} SELFHEAL_PORT=${port} /root/07-setup-selfheal.sh --configure"; then
            applied=$((applied + 1))
        else
            echo "WARN: self-healing failed on $name (CT $ctid)" >&2
            failed=$((failed + 1))
        fi
    done

    cat <<EOF

================================================================
ACK self-healing: applied=$applied skipped=$skipped failed=$failed

Each host now has:
  - Restart=always + StartLimitIntervalSec=0 on its service
  - a port probe every 60s (3 failures -> restart, 3 failed restarts -> reboot)

Re-run any time to repair drift:
  ./07-setup-selfheal.sh --repair

Inspect a host:
  pct exec <ctid> -- journalctl -t ack-healthcheck -n 50
  pct exec <ctid> -- systemctl list-timers ack-healthcheck.timer
================================================================
EOF

    [[ $failed -eq 0 ]]
}

if [[ "${1:-}" == "--configure" ]]; then
    configure
else
    host_main "$@"
fi
