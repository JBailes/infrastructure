#!/usr/bin/env bash
# Test harness for the vpn-healthcheck escalation ladder.
# Stubs probe/systemctl/logger and drives the state machine.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/bin" "$SANDBOX/run" "$SANDBOX/metrics"

# Extract the watchdog exactly as it is embedded in the bootstrap script.
sed -n "/cat > \/usr\/local\/bin\/vpn-healthcheck.sh <<'HEALTH'/,/^HEALTH$/p" \
    "${ROOT}/homelab/bootstrap/lib/vpn-selfheal.sh" | sed '1d;$d' > "$SANDBOX/wd.sh"

# Redirect state/metric paths into the sandbox.
sed -i "s|STATE_DIR=\"/run/vpn-healthcheck\"|STATE_DIR=\"${SANDBOX}/run\"|" "$SANDBOX/wd.sh"
sed -i "s|METRIC_DIR=\"/var/lib/prometheus/node-exporter\"|METRIC_DIR=\"${SANDBOX}/metrics\"|" "$SANDBOX/wd.sh"
chmod +x "$SANDBOX/wd.sh"

# Stubs. PROBE_RESULT and FAKE_UPTIME drive the scenario.
cat > "$SANDBOX/bin/ping" <<'EOF'
#!/usr/bin/env bash
exit "${PROBE_RESULT:-1}"
EOF
cat > "$SANDBOX/bin/ip" <<'EOF'
#!/usr/bin/env bash
exit "${IFACE_RESULT:-0}"
EOF
cat > "$SANDBOX/bin/logger" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$SANDBOX/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "SYSTEMCTL $*" >> "$SANDBOX_ACTIONS"
exit 0
EOF
chmod +x "$SANDBOX"/bin/*

export SANDBOX_ACTIONS="$SANDBOX/actions.log"
: > "$SANDBOX_ACTIONS"
export PATH="$SANDBOX/bin:$PATH"

# /proc/uptime is read directly; override via a wrapper on awk is fragile, so
# tests that need the reboot path set a real long uptime expectation instead.
run() { "$SANDBOX/wd.sh" >/dev/null 2>&1; }
metric() { grep "^$1 " "$SANDBOX/metrics/vpn_gateway.prom" | awk '{print $2}'; }
actions() { cat "$SANDBOX_ACTIONS"; }

pass=0; fail=0
check() {
    local desc="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        echo "  PASS: $desc"; pass=$((pass+1))
    else
        echo "  FAIL: $desc (got '$got', want '$want')"; fail=$((fail+1))
    fi
}

echo "== Scenario 1: healthy tunnel =="
PROBE_RESULT=0 run
check "tunnel_up is 1" "$(metric vpn_gateway_tunnel_up)" "1"
check "no failures recorded" "$(metric vpn_gateway_probe_failures)" "0"
check "no restart issued" "$(actions | grep -c restart || true)" "0"

echo "== Scenario 2: failures below threshold do not restart =="
: > "$SANDBOX_ACTIONS"
PROBE_RESULT=1 run
check "1st failure counted" "$(metric vpn_gateway_probe_failures)" "1"
PROBE_RESULT=1 run
check "2nd failure counted" "$(metric vpn_gateway_probe_failures)" "2"
check "still no restart" "$(actions | grep -c restart || true)" "0"
check "tunnel_up is 0" "$(metric vpn_gateway_tunnel_up)" "0"

echo "== Scenario 3: 3rd failure triggers restart =="
PROBE_RESULT=1 run
check "restart issued" "$(actions | grep -c 'restart openvpn@client' || true)" "1"
check "failure counter reset" "$(metric vpn_gateway_probe_failures)" "0"
check "restart counter is 1" "$(metric vpn_gateway_restarts_since_recovery)" "1"

echo "== Scenario 4: recovery clears all counters =="
PROBE_RESULT=0 run
check "tunnel_up back to 1" "$(metric vpn_gateway_tunnel_up)" "1"
check "restart counter cleared" "$(metric vpn_gateway_restarts_since_recovery)" "0"

echo "== Scenario 5: repeated failure escalates to reboot =="
: > "$SANDBOX_ACTIONS"
# 3 restarts require 9 failed probes, then 3 more to hit the reboot branch.
for _ in $(seq 1 12); do PROBE_RESULT=1 run; done
check "three restarts attempted" "$(actions | grep -c 'restart openvpn@client' || true)" "3"
reboot_or_holdoff="$(actions | grep -c 'reboot' || true)"
uptime_now="$(awk '{print int($1)}' /proc/uptime)"
if [[ "$uptime_now" -ge 1200 ]]; then
    check "reboot issued after 3 failed restarts" "$reboot_or_holdoff" "1"
else
    check "reboot held off on low uptime (boot-loop guard)" "$reboot_or_holdoff" "0"
fi

echo
echo "passed=$pass failed=$fail"
[[ "$fail" -eq 0 ]]
