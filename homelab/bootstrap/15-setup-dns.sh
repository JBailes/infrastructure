#!/usr/bin/env bash
# 15-setup-dns.sh -- Configure the local DNS resolver (CT 101 `dns`)
#
# Runs on: the Proxmox host
# Run order: Step 15 (any time; other hosts depend on it for name resolution)
#
# Usage:
#   ./15-setup-dns.sh                 # sync zone records and forwarders
#   ./15-setup-dns.sh --dry-run       # show what would change, change nothing
#   ./15-setup-dns.sh --show          # list current records and exit
#
# WHY THIS EXISTS
# Every host address in this repo used to be written down by hand, in scripts
# and in docs, and every one of them went stale when the containers were
# renumbered -- silently, because nothing checks a comment. The fix is to stop
# writing addresses down: hosts get names, and the names resolve here.
#
# So this script does NOT carry a list of addresses. It reads the live guest
# list from Proxmox and syncs the zone to match. Renumber a container and the
# next run corrects DNS; nothing else in the repo needs to know.
#
# Guests with no static address are skipped rather than guessed at:
#   - no network interface at all (e.g. OCI containers on host networking)
#   - DHCP addresses, which would drift the moment the lease changed
#
# The resolver forwards anything it is not authoritative for to the router.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

DNS_HOST="dns"                 # resolved to a CTID via Proxmox, never hardcoded
DNS_ZONE="${DNS_ZONE:-bailes.us}"
DNS_API_PORT=5380
DNS_ADMIN_USER="${DNS_ADMIN_USER:-admin}"
DNS_ADMIN_PASS="${DNS_ADMIN_PASS:-admin}"
UPSTREAM="$ROUTER_GW"          # the resolver upstreams to the home router
RECORD_TTL=3600

DRY_RUN=0
SHOW_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --show)    SHOW_ONLY=1 ;;
    esac
done

[[ $EUID -eq 0 ]] || err "Run as root"

# --- Locate the resolver itself by name, not by address ---------------------
DNS_CTID="$(resolve_ctid "$DNS_HOST")" || err "No guest named '$DNS_HOST' on this host"
DNS_IP="$(guest_ip "$DNS_CTID")" || err "Could not determine an address for CT $DNS_CTID ($DNS_HOST)"
API="http://${DNS_IP}:${DNS_API_PORT}/api"

api() {
    local path="$1"; shift
    local url="${API}/${path}?token=${TOKEN}"
    local kv
    for kv in "$@"; do url+="&${kv}"; done
    curl -sf --max-time 15 --get --data-urlencode "dummy=" "$url" 2>/dev/null \
        || curl -sf --max-time 15 "$url"
}

api_status() { python3 -c 'import sys,json; print(json.load(sys.stdin).get("status","error"))'; }

# --- Authenticate -----------------------------------------------------------
TOKEN="$(curl -sf --max-time 15 \
    "${API}/user/login?user=${DNS_ADMIN_USER}&pass=${DNS_ADMIN_PASS}" \
    | python3 -c 'import sys,json; print(json.load(sys.stdin).get("token",""))')"
[[ -n "$TOKEN" ]] || err "Could not authenticate to Technitium at ${DNS_IP}:${DNS_API_PORT}. Set DNS_ADMIN_PASS."

if [[ $SHOW_ONLY -eq 1 ]]; then
    api "zones/records/get" "domain=${DNS_ZONE}" "zone=${DNS_ZONE}" "listZone=true" \
        | python3 -c '
import sys, json
for r in json.load(sys.stdin).get("response", {}).get("records", []):
    if r.get("type") == "A":
        print(f"{r[\"name\"]:36} {r[\"rData\"][\"ipAddress\"]}")
'
    exit 0
fi

# --- Build the desired record set from live Proxmox state -------------------
info "Reading guest list from Proxmox"

declare -A DESIRED
skipped=()

collect() {
    local id="$1" name="$2" ip="$3"
    if [[ -z "$ip" ]]; then
        skipped+=("$id $name (no static address)")
        return
    fi
    DESIRED["$name"]="$ip"
}

while read -r id name; do
    [[ -n "$id" ]] || continue
    collect "$id" "$name" "$(guest_ip "$id" || true)"
done < <(guest_list)

# Infrastructure that is not a Proxmox guest still needs a name.
DESIRED["pve"]="$(hostname -I | awk '{print $1}')"
DESIRED["nas"]="$NAS_IP"

# --- Sync -------------------------------------------------------------------
declare -A CURRENT
while read -r fqdn ip; do
    [[ -n "$fqdn" ]] || continue
    CURRENT["${fqdn%.$DNS_ZONE}"]="$ip"
done < <(api "zones/records/get" "domain=${DNS_ZONE}" "zone=${DNS_ZONE}" "listZone=true" \
    | python3 -c '
import sys, json
for r in json.load(sys.stdin).get("response", {}).get("records", []):
    if r.get("type") == "A":
        print(r["name"], r["rData"]["ipAddress"])
')

changes=0
for name in $(printf '%s\n' "${!DESIRED[@]}" | sort); do
    want="${DESIRED[$name]}"
    have="${CURRENT[$name]:-}"
    [[ "$want" == "$have" ]] && continue

    changes=$((changes + 1))
    if [[ -n "$have" ]]; then
        info "UPDATE ${name}.${DNS_ZONE}: ${have} -> ${want}"
    else
        info "ADD    ${name}.${DNS_ZONE}: ${want}"
    fi

    [[ $DRY_RUN -eq 1 ]] && continue

    # addRecord with overwrite replaces any existing A for the name.
    api "zones/records/add" \
        "domain=${name}.${DNS_ZONE}" "zone=${DNS_ZONE}" \
        "type=A" "ipAddress=${want}" "ttl=${RECORD_TTL}" "overwrite=true" \
        >/dev/null || warn "failed to set ${name}.${DNS_ZONE}"
done

# --- Forwarders -------------------------------------------------------------
if [[ $DRY_RUN -eq 0 ]]; then
    info "Setting forwarder to ${UPSTREAM}"
    api "settings/set" "forwarders=${UPSTREAM}" "forwarderProtocol=Udp" >/dev/null \
        || warn "could not set forwarders"
fi

# --- Point LAN guests at the resolver ---------------------------------------
# Without this the zone is correct but unused, which is exactly the state this
# infrastructure was already in: a working resolver nothing queried.
#
# Two guests are deliberately left alone:
#   bittorrent  -- its DNS must stay on the VPN gateway. Its firewall DROPs
#                  port 53 to anything else, which is the DNS-leak guard.
#                  Repointing it here would be a real regression.
#   dns         -- the resolver itself.
#   ack-gateway -- runs dnsmasq as the ACK network's resolver. Its own
#                  /etc/resolv.conf feeds that, so changing it here would
#                  quietly change DNS for every ACK host.
#
# The router stays as a secondary so external names still resolve if CT 101 is
# down; internal names will not, which is the accepted trade.
repoint_clients() {
    local id name cfg current
    while read -r id name; do
        [[ -n "$id" ]] || continue
        case "$name" in
            bittorrent|ack-gateway|"$DNS_HOST") continue ;;
        esac

        cfg=$(pct config "$id" 2>/dev/null) || continue          # LXC only
        grep -q "bridge=${LAN_BRIDGE}" <<<"$cfg" || continue     # LAN guests only
        guest_ip "$id" >/dev/null 2>&1 || continue               # static only

        current=$(awk '/^nameserver:/ {$1=""; sub(/^ /,""); print}' <<<"$cfg")
        [[ "$current" == "$DNS_IP $UPSTREAM" ]] && continue

        info "REPOINT CT ${id} (${name}): nameserver '${current:-<inherited>}' -> '${DNS_IP} ${UPSTREAM}'"
        [[ $DRY_RUN -eq 1 ]] && continue

        pct set "$id" --nameserver "${DNS_IP} ${UPSTREAM}" >/dev/null

        # pct set only rewrites /etc/resolv.conf on next start; update the
        # running container too so this takes effect without a restart.
        if pct status "$id" 2>/dev/null | grep -q running; then
            pct exec "$id" -- sh -c \
                "printf 'search %s\nnameserver %s\nnameserver %s\n' '$DNS_ZONE' '$DNS_IP' '$UPSTREAM' > /etc/resolv.conf" \
                2>/dev/null || warn "CT $id: could not update live /etc/resolv.conf"
        fi
    done < <(guest_list)
}

repoint_clients

# --- Point the Proxmox host itself at the resolver --------------------------
# The host runs bootstrap scripts that reference other hosts by name, so it
# needs the local zone too. The router stays as a secondary: the host provides
# the resolver, so it must still resolve something if that container is down.
repoint_pve() {
    local want_primary="$DNS_IP"
    if grep -q "^nameserver ${want_primary}\$" /etc/resolv.conf 2>/dev/null; then
        return 0
    fi

    info "REPOINT pve: nameserver -> '${want_primary} ${UPSTREAM}'"
    [[ $DRY_RUN -eq 1 ]] && return 0

    cp /etc/resolv.conf "/etc/resolv.conf.bak-$(date +%s)"
    printf 'search %s\nnameserver %s\nnameserver %s\n' \
        "$DNS_ZONE" "$want_primary" "$UPSTREAM" > /etc/resolv.conf
}

repoint_pve

# --- Report -----------------------------------------------------------------
if ((${#skipped[@]})); then
    echo
    warn "Skipped (no static address -- give them a DHCP reservation if you want a name):"
    printf '  %s\n' "${skipped[@]}" >&2
fi

cat <<EOF

================================================================
DNS resolver: CT ${DNS_CTID} (${DNS_HOST}), zone ${DNS_ZONE}
Records synced from live Proxmox state: ${changes} change(s)
Forwarding anything else to ${UPSTREAM}

Records are DERIVED, not written down. Re-run after any renumber
and the zone corrects itself:

  ./15-setup-dns.sh --dry-run    # preview
  ./15-setup-dns.sh --show       # list current records
================================================================
EOF
