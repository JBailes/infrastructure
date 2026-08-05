#!/usr/bin/env bash
# dns-register.sh -- Register a host's A record in the internal DNS zone
#
# Usage:
#   dns-register.sh <hostname> <ip> [--token-file /etc/dns-api-token]
#   dns-register.sh --self                 # derive name and IP from this host
#
# Because CTIDs are allocated dynamically, a host does not know its address
# until it exists. Rather than maintaining a static map, each host claims its
# own name here at the end of its bootstrap, and Terraform does the same for
# what it provisions. Re-running is safe: records are written with
# overwrite=true, so this doubles as a repair step when a record drifts.
#
# The token comes from the dns host (/etc/dns-api-token). It is a non-expiring
# automation token, not the admin password.

set -euo pipefail

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

INTERNAL_ZONE="${INTERNAL_ZONE:-bailes.us}"
DNS_SERVER="${DNS_SERVER:-192.168.1.101}"
TOKEN_FILE="${DNS_TOKEN_FILE:-/etc/dns-api-token}"

name="" ip=""
case "${1:-}" in
    --self)
        name="$(hostname -s)"
        # First non-loopback IPv4 on the default route interface.
        iface=$(ip -4 route show default | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
        [[ -n "$iface" ]] || err "could not determine the default interface"
        ip=$(ip -4 -o addr show dev "$iface" | awk '{split($4,a,"/"); print a[1]; exit}')
        [[ -n "$ip" ]] || err "could not determine an IPv4 address on ${iface}"
        ;;
    "")
        err "usage: dns-register.sh <hostname> <ip> | --self"
        ;;
    *)
        name="$1"
        ip="${2:?usage: dns-register.sh <hostname> <ip>}"
        ;;
esac

[[ -r "$TOKEN_FILE" ]] || err "API token not readable at ${TOKEN_FILE}"
token="$(cat "$TOKEN_FILE")"
[[ -n "$token" ]] || err "API token at ${TOKEN_FILE} is empty"

fqdn="${name}.${INTERNAL_ZONE}"

response=$(curl -sf -G "http://${DNS_SERVER}:5380/api/zones/records/add" \
    --data-urlencode "token=${token}" \
    --data-urlencode "zone=${INTERNAL_ZONE}" \
    --data-urlencode "domain=${fqdn}" \
    --data-urlencode "type=A" \
    --data-urlencode "ipAddress=${ip}" \
    --data-urlencode "ttl=300" \
    --data-urlencode "overwrite=true" 2>/dev/null) \
    || err "could not reach the DNS API at ${DNS_SERVER}:5380"

# A non-ok status still returns HTTP 200, so inspect the body.
status=$(echo "$response" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)
[[ "$status" == "ok" ]] \
    || err "registration failed for ${fqdn}: ${response}"

info "Registered ${fqdn} -> ${ip}"
