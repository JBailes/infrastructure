#!/usr/bin/env bash
# Destroy guests ahead of the sequential rebuild.
#
# Phase 1 touches nothing that serves public traffic.
# Phase 2 destroys the web-facing hosts, which are down until rebuilt.
#
# Every target is matched against its EXPECTED hostname before anything is
# destroyed: an ID reused for something else aborts the run rather than
# taking an unintended guest with it. Anything on PROTECTED is never touched.
set -uo pipefail

PVE="root@192.168.1.253"
PHASE="${1:?usage: wipe.sh <1|2>}"

PHASE1=(
    "101:ct:smoothfs-gate"
    "105:ct:plex"
    "106:ct:aimee-ci-rig"
    "103:vm:aimee-e2e-test"
    "200:ct:wol-gateway-a"
    "201:ct:wol-gateway-b"
    "202:ct:spire-db"
    "203:ct:ca"
    "204:vm:spire-server"
    "205:ct:provisioning"
    "206:ct:wol-accounts-db"
    "207:ct:wol-accounts"
    "208:ct:wol-a"
    "209:ct:wol-web"
    "210:ct:wol-realm-prod"
    "211:ct:wol-world-prod"
    "212:ct:wol-ai-prod"
    "213:ct:wol-world-db-prod"
    "214:ct:wol-realm-db-prod"
    "215:ct:wol-realm-test"
    "216:ct:wol-world-test"
    "217:ct:wol-ai-test"
    "218:ct:wol-world-db-test"
    "219:ct:wol-realm-db-test"
    "220:ct:wol-root-ca"
)

PHASE2=(
    "115:ct:apt-cache"
    "116:ct:bittorrent"
    "117:ct:personal-web"
    "118:ct:nginx-proxy"
    "119:ct:media-stack"
    "121:ct:rakuen-web"
    "104:vm:vpn-gateway"
)

# code, unifi, the rest of the aimee fleet, and all of ACK.
PROTECTED="100 102 130 131 132 140 240 241 242 243 244 245 246 247 248 249 250 260 261 262 263 264 265 266 267 268 270 271 272 280 281 300 301 302 303 310 311 320 321 330 331 340 341 391 999"

if [[ "$PHASE" == "1" ]]; then
    TARGETS=("${PHASE1[@]}")
else
    TARGETS=("${PHASE2[@]}")
fi

echo "=== Phase ${PHASE}: verifying ${#TARGETS[@]} targets ==="
verified=()
abort=0

for entry in "${TARGETS[@]}"; do
    IFS=':' read -r id kind want <<< "$entry"

    if grep -qw "$id" <<< "$PROTECTED"; then
        echo "ABORT: $id is protected"
        abort=1
        continue
    fi

    if [[ "$kind" == "ct" ]]; then
        got=$(ssh -o BatchMode=yes "$PVE" "pct config $id 2>/dev/null | awk -F': ' '/^hostname:/{print \$2}'")
    else
        got=$(ssh -o BatchMode=yes "$PVE" "qm config $id 2>/dev/null | awk -F': ' '/^name:/{print \$2}'")
    fi

    if [[ -z "$got" ]]; then
        echo "  --  $kind $id does not exist, skipping"
        continue
    fi

    if [[ "$got" != "$want" ]]; then
        echo "ABORT: $kind $id is '$got', expected '$want'"
        abort=1
        continue
    fi

    echo "  OK  $kind $id = $got"
    verified+=("$id:$kind:$got")
done

if [[ $abort -eq 1 ]]; then
    echo
    echo "Aborting: a target did not match. NOTHING destroyed."
    exit 1
fi

echo
echo "=== Destroying ${#verified[@]} guests ==="
failed=0
for entry in "${verified[@]}"; do
    IFS=':' read -r id kind name <<< "$entry"
    printf "  %-4s %-22s " "$id" "$name"
    if [[ "$kind" == "ct" ]]; then
        ssh -o BatchMode=yes "$PVE" "pct stop $id 2>/dev/null; sleep 2; pct destroy $id --purge 1" >/dev/null 2>&1
        still=$(ssh -o BatchMode=yes "$PVE" "pct status $id 2>/dev/null" || true)
    else
        ssh -o BatchMode=yes "$PVE" "qm stop $id 2>/dev/null; sleep 2; qm destroy $id --purge 1" >/dev/null 2>&1
        still=$(ssh -o BatchMode=yes "$PVE" "qm status $id 2>/dev/null" || true)
    fi

    if [[ -n "$still" ]]; then
        echo "STILL PRESENT"
        failed=1
    else
        echo "destroyed"
    fi
done

echo
echo "=== Remaining guests ==="
ssh -o BatchMode=yes "$PVE" 'pct list | awk "NR>1{printf \"%s %s\n\", \$1, \$3}"; echo "-- VMs --"; qm list | awk "NR>1{printf \"%s %s\n\", \$1, \$2}"'

exit $failed
