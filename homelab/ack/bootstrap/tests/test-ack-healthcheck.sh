#!/usr/bin/env bash
# Test harness for the ack-healthcheck escalation ladder.
#
# The port probe is exercised for real: a live listener stands in for a
# healthy service, and a closed port for a wedged one. Only systemctl is
# stubbed, so the /dev/tcp probe itself is genuinely under test.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"; [[ -n "${LISTENER_PID:-}" ]] && kill "$LISTENER_PID" 2>/dev/null' EXIT
mkdir -p "$SANDBOX/bin" "$SANDBOX/run"

SRC="${ROOT}/homelab/ack/bootstrap/07-setup-selfheal.sh"
[[ -f "$SRC" ]] || { echo "cannot find $SRC"; exit 1; }

# Extract the health script exactly as it is embedded.
sed -n "/cat > \/usr\/local\/bin\/ack-healthcheck.sh <<'HEALTH'/,/^HEALTH\$/p" "$SRC" \
    | sed '1d;$d' > "$SANDBOX/hc.sh"
sed -i "s|STATE_DIR=\"/run/ack-healthcheck\"|STATE_DIR=\"${SANDBOX}/run\"|" "$SANDBOX/hc.sh"
chmod +x "$SANDBOX/hc.sh"

export SANDBOX_ACTIONS="$SANDBOX/actions.log"
: > "$SANDBOX_ACTIONS"

cat > "$SANDBOX/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
# is-enabled gates the whole watchdog; UNIT_ENABLED drives it.
if [[ "$1" == "is-enabled" ]]; then
    exit "${UNIT_ENABLED:-0}"
fi
echo "SYSTEMCTL $*" >> "$SANDBOX_ACTIONS"
exit 0
EOF
cat > "$SANDBOX/bin/logger" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$SANDBOX"/bin/*
export PATH="$SANDBOX/bin:$PATH"

# A real listener on a free port = healthy service.
python3 -c "
import socket,threading
s=socket.socket(); s.bind(('127.0.0.1',0)); s.listen(16)
print(s.getsockname()[1],flush=True)
threading.Thread(target=lambda:[s.accept() for _ in iter(int,1)],daemon=True).start()
import time; time.sleep(3600)
" > "$SANDBOX/port.txt" &
LISTENER_PID=$!
sleep 1
OPEN_PORT="$(head -1 "$SANDBOX/port.txt")"
[[ -n "$OPEN_PORT" ]] || { echo "failed to start test listener"; exit 1; }
CLOSED_PORT=1   # nothing listens on port 1

run() { "$SANDBOX/hc.sh" mud "$1" >/dev/null 2>&1; }
actions() { cat "$SANDBOX_ACTIONS"; }
counter() { cat "$SANDBOX/run/mud.$1" 2>/dev/null || echo 0; }

pass=0; fail=0
check() {
    if [[ "$2" == "$3" ]]; then echo "  PASS: $1"; pass=$((pass+1));
    else echo "  FAIL: $1 (got '$2', want '$3')"; fail=$((fail+1)); fi
}

echo "== Probe works against a real listener =="
run "$OPEN_PORT"
check "healthy probe records no failures" "$(counter failures)" "0"
check "healthy probe issues no restart" "$(actions | grep -c restart || true)" "0"

echo "== Disabled unit is left alone =="
: > "$SANDBOX_ACTIONS"
UNIT_ENABLED=1 run "$CLOSED_PORT"
check "no action taken on a disabled unit" "$(actions | wc -l)" "0"
check "no failure counted for a disabled unit" "$(counter failures)" "0"

echo "== Failures below threshold do not restart =="
: > "$SANDBOX_ACTIONS"
run "$CLOSED_PORT"
check "1st failure counted" "$(counter failures)" "1"
run "$CLOSED_PORT"
check "2nd failure counted" "$(counter failures)" "2"
check "still no restart" "$(actions | grep -c restart || true)" "0"

echo "== 3rd failure restarts the unit =="
run "$CLOSED_PORT"
check "restart issued" "$(actions | grep -c 'restart mud.service' || true)" "1"
check "failure counter reset" "$(counter failures)" "0"
check "restart counter incremented" "$(counter restarts)" "1"

echo "== Recovery clears counters =="
run "$OPEN_PORT"
check "restart counter cleared" "$(counter restarts)" "0"
check "failure counter cleared" "$(counter failures)" "0"

echo "== Repeated failure escalates to reboot =="
: > "$SANDBOX_ACTIONS"
for _ in $(seq 1 12); do run "$CLOSED_PORT"; done
check "three restarts attempted" "$(actions | grep -c 'restart mud.service' || true)" "3"
uptime_now="$(awk '{print int($1)}' /proc/uptime)"
if [[ "$uptime_now" -ge 900 ]]; then
    check "reboot issued after 3 failed restarts" "$(actions | grep -c reboot || true)" "1"
else
    check "reboot held off on low uptime (boot-loop guard)" "$(actions | grep -c reboot || true)" "0"
fi

echo
echo "passed=$pass failed=$fail"
[[ "$fail" -eq 0 ]]
