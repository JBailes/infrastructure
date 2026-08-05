#!/usr/bin/env bash
# Phase 1 wipe: WOL stack, plex, smoothfs-gate.
#
# Nothing here serves public traffic, so this phase causes no outage.
#
# Every target is matched against its EXPECTED hostname before anything is
# destroyed. An ID that has been reused for something else aborts the run
# rather than taking an unintended guest with it.
set -uo pipefail

PVE="root@192.168.1.253"

# id:type:expected-hostname
TARGETS=(
    "101:ct:smoothfs-gate"
    "105:ct:plex"
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

# Never destroy these, whatever else happens.
PROTECTED="100 102 103 106 130 131 132 140 240 241 242 243 244 245 246 247 248 249 250 260 261 262 263 264 265 266 267 268 270 271 272 280 281 300 301 302 303 310 311 320 321 330 331 340 341 391 999"

echo "=== Verifying targets before destroying anything ==="
verified=()
abort=0

for entry in "${TARGETS[@]}"; do
    IFS=':' read -r id kind want <<< "$entry"

    if grep -qw "$id" <<< "$PROTECTED"; then
        echo "ABORT: $id is on the protected list"
        abort=1
        continue
    fi

    if [[ "$kind" == "ct" ]]; then
        got=$(ssh -o BatchMode=yes "$PVE" "pct config $id 2>/dev/null | awk -F': ' '/^hostname:/{print \$2}'")
    else
        got=$(ssh -o BatchMode=yes "$PVE" "qm config $id 2>/dev/null | awk -F': ' '/^name:/{print \$2}'")
    fi

    if [[ -z "$got" ]]; then
        echo "SKIP: $kind $id does not exist"
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
    echo "Aborting: at least one target did not match. Nothing destroyed."
    exit 1
fi

echo
echo "=== Destroying ${#verified[@]} guests ==="
for entry in "${verified[@]}"; do
    IFS=':' read -r id kind name <<< "$entry"
    printf "  %-4s %-22s " "$id" "$name"
    if [[ "$kind" == "ct" ]]; then
        ssh -o BatchMode=yes "$PVE" "pct stop $id --skiplock 2>/dev/null; sleep 1; pct destroy $id --purge --destroy-unreferenced-disks 1" >/dev/null 2>&1
    else
        ssh -o BatchMode=yes "$PVE" "qm stop $id --skiplock 2>/dev/null; sleep 1; qm destroy $id --purge --destroy-unreferenced-disks 1" >/dev/null 2>&1
    fi
    if ssh -o BatchMode=yes "$PVE" "pct status $id &>/dev/null || qm status $id &>/dev/null"; then
        echo "STILL PRESENT"
    else
        echo "destroyed"
    fi
done

echo
echo "=== Remaining guests ==="
ssh -o BatchMode=yes "$PVE" 'pct list | awk "NR>1{print \$1, \$3}"; qm list | awk "NR>1{print \$1, \$2}"'
