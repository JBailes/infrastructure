#!/usr/bin/env bash
# 05-setup-dns.sh -- Create and configure the internal DNS host (Technitium)
#
# Runs on: the Proxmox host (creates the CT, then configures it)
# Run order: Step 05 -- after apt-cache, before everything that uses hostnames
#
# Usage:
#   ./05-setup-dns.sh                # Create CT and configure
#   ./05-setup-dns.sh --deploy-only  # Re-run configuration on the existing CT
#   ./05-setup-dns.sh --configure    # (internal) Run inside the container
#
# WHAT THIS IS
#
# Technitium DNS, authoritative for the internal zone (default bailes.us) on
# the LAN, forwarding everything else to the router at 192.168.1.1.
#
# SPLIT HORIZON -- READ THIS BEFORE ADDING PUBLIC RECORDS
#
# Because this server is *authoritative* for bailes.us internally, it answers
# for the whole zone and never forwards a bailes.us lookup upstream. Any name
# under bailes.us that is not in the internal zone returns NXDOMAIN on the
# LAN, even if it resolves fine on the public internet.
#
# That is the point (internal names resolve to internal IPs), but it means
# every public bailes.us record you care about from inside the LAN must be
# mirrored into this zone. Names outside the zone -- google.com, and the other
# domains such as rakuensoftware.com and ackmud.com -- are forwarded to the
# router and are unaffected.
#
# DYNAMIC ADDRESSING
#
# CTIDs are allocated dynamically and a host's IP is 192.168.1.<CTID>, so
# records are NOT hardcoded here. Hosts register themselves via the API using
# lib/dns-register.sh, and Terraform registers what it provisions. This host
# is the one bootstrap floor: it needs a known IP so everything else has
# somewhere to ask. That IP is DNS_IP in lib/common.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ===================================================================
# In-container configuration
# ===================================================================

configure() {
    err()  { echo "ERROR: $*" >&2; exit 1; }
    info() { echo "==> $*"; }

    INTERNAL_ZONE="${INTERNAL_ZONE:-bailes.us}"
    ROUTER_GW="${ROUTER_GW:-192.168.1.1}"
    APT_CACHE_IP="${APT_CACHE_IP:-192.168.1.115}"
    DNS_IP="${DNS_IP:-192.168.1.101}"
    ADMIN_PASSWORD="${DNS_ADMIN_PASSWORD:-}"
    API="http://127.0.0.1:5380/api"

    [[ $EUID -eq 0 ]] || err "Run as root"
    [[ -n "$ADMIN_PASSWORD" ]] || err "DNS_ADMIN_PASSWORD must be set (do not ship a default admin password)"

    # Use the apt cache only if it actually answers.
    #
    # dns is the first host brought up on a cold rebuild, so apt-cache may not
    # exist yet. Pointing at a dead proxy makes every package fetch fail with
    # "no route to host" -- the resolver cannot be installed because the cache
    # it does not need is missing.
    configure_apt_proxy() {
        mkdir -p /etc/apt/apt.conf.d
        rm -f /etc/apt/apt.conf.d/01proxy

        if timeout 3 bash -c "exec 3<>/dev/tcp/${APT_CACHE_IP}/3142" 2>/dev/null; then
            info "Using apt cache at ${APT_CACHE_IP}:3142"
            echo "Acquire::http::Proxy \"http://${APT_CACHE_IP}:3142\";" \
                > /etc/apt/apt.conf.d/01proxy
        else
            info "apt cache unreachable at ${APT_CACHE_IP}:3142, fetching directly"
        fi
    }

    # Technitium binds :53. systemd-resolved must be out of the way first.
    disable_resolved() {
        if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
            info "Disabling systemd-resolved (port 53 conflict)"
            systemctl stop systemd-resolved
            systemctl disable systemd-resolved
        fi
        rm -f /etc/resolv.conf
        # This host must not point at itself while it is still being set up.
        cat > /etc/resolv.conf <<EOF
nameserver ${ROUTER_GW}
nameserver 1.1.1.1
EOF
    }

    install_packages() {
        info "Installing packages"
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
            curl ca-certificates jq chrony
    }

    install_technitium() {
        if systemctl is-active --quiet dns 2>/dev/null; then
            info "Technitium already installed"
            return
        fi
        info "Installing Technitium DNS Server"
        curl -sSL https://download.technitium.com/dns/install.sh | bash \
            || err "Technitium installer failed"

        # The installer starts dns.service; wait for the API to answer.
        for _ in $(seq 1 30); do
            curl -sf "${API}/user/login?user=admin&pass=admin" &>/dev/null && break
            sleep 2
        done
    }

    # -- API plumbing --------------------------------------------------
    #
    # Technitium's HTTP API returns {"status":"ok"|"error", ...}. A non-ok
    # status still comes back as HTTP 200, so every call must inspect the
    # body. Failing loudly here matters: a half-configured resolver that
    # silently answers nothing is worse than no resolver at all.

    TOKEN=""

    api() {
        local path="$1"; shift
        local response
        response=$(curl -sf -G "${API}/${path}" "$@" 2>/dev/null) \
            || err "API call failed: ${path}"
        local status
        status=$(echo "$response" | jq -r '.status // "error"')
        if [[ "$status" != "ok" ]]; then
            err "API ${path} returned: $(echo "$response" | jq -r '.errorMessage // .status')"
        fi
        echo "$response"
    }

    login() {
        info "Authenticating to the Technitium API"
        local response pass
        # First run uses the installer default; later runs use our password.
        for pass in "$ADMIN_PASSWORD" "admin"; do
            response=$(curl -sf -G "${API}/user/login" \
                --data-urlencode "user=admin" \
                --data-urlencode "pass=${pass}" 2>/dev/null) || continue
            if [[ "$(echo "$response" | jq -r '.status // "error"')" == "ok" ]]; then
                TOKEN=$(echo "$response" | jq -r '.token')
                CURRENT_PASSWORD="$pass"
                [[ "$pass" == "admin" ]] && CHANGE_PASSWORD=1
                return 0
            fi
        done
        err "Could not authenticate to the Technitium API"
    }

    secure_admin() {
        if [[ "${CHANGE_PASSWORD:-0}" == "1" ]]; then
            info "Changing the default admin password"
            # Both parameters are required: 'pass' is the CURRENT password and
            # 'newPass' the replacement. Sending either alone fails with the
            # other reported missing.
            api "user/changePassword" \
                --data-urlencode "token=${TOKEN}" \
                --data-urlencode "pass=${CURRENT_PASSWORD}" \
                --data-urlencode "newPass=${ADMIN_PASSWORD}" >/dev/null
        fi
    }

    # Forward everything that is not in an authoritative zone to the router,
    # so internal clients keep getting the router's view of the internet.
    configure_forwarders() {
        info "Setting forwarders to ${ROUTER_GW}"
        api "settings/set" \
            --data-urlencode "token=${TOKEN}" \
            --data-urlencode "dnsServerDomain=dns.${INTERNAL_ZONE}" \
            --data-urlencode "forwarders=${ROUTER_GW}" \
            --data-urlencode "forwarderProtocol=Udp" \
            --data-urlencode "recursion=UseSpecifiedNetworks" \
            --data-urlencode "recursionAllowedNetworks=192.168.0.0/23,10.1.0.0/24,127.0.0.0/8" >/dev/null
    }

    create_zone() {
        # Creating an existing zone is an error, not a no-op -- check first.
        local zones
        zones=$(api "zones/list" --data-urlencode "token=${TOKEN}")
        if echo "$zones" | jq -e --arg z "$INTERNAL_ZONE" '.response.zones[]? | select(.name == $z)' >/dev/null; then
            info "Zone ${INTERNAL_ZONE} already exists"
        else
            info "Creating authoritative zone ${INTERNAL_ZONE}"
            api "zones/create" \
                --data-urlencode "token=${TOKEN}" \
                --data-urlencode "zone=${INTERNAL_ZONE}" \
                --data-urlencode "type=Primary" >/dev/null
        fi

        # The DNS host's own record is the bootstrap anchor.
        info "Registering dns.${INTERNAL_ZONE} -> ${DNS_IP}"
        api "zones/records/add" \
            --data-urlencode "token=${TOKEN}" \
            --data-urlencode "zone=${INTERNAL_ZONE}" \
            --data-urlencode "domain=dns.${INTERNAL_ZONE}" \
            --data-urlencode "type=A" \
            --data-urlencode "ipAddress=${DNS_IP}" \
            --data-urlencode "ttl=300" \
            --data-urlencode "overwrite=true" >/dev/null
    }

    # A non-expiring token so hosts and Terraform can register records
    # without holding the admin password.
    create_api_token() {
        info "Creating the automation API token"
        local response
        response=$(curl -sf -G "${API}/user/createToken" \
            --data-urlencode "user=admin" \
            --data-urlencode "pass=${ADMIN_PASSWORD}" \
            --data-urlencode "tokenName=automation" 2>/dev/null) \
            || err "Could not create API token"
        if [[ "$(echo "$response" | jq -r '.status // "error"')" != "ok" ]]; then
            err "Token creation failed: $(echo "$response" | jq -r '.errorMessage // .status')"
        fi
        umask 077
        echo "$response" | jq -r '.token' > /etc/dns-api-token
        chmod 0600 /etc/dns-api-token
        info "Automation token written to /etc/dns-api-token"
    }

    # Now that the server is authoritative, point this host at itself.
    point_self_at_technitium() {
        cat > /etc/resolv.conf <<EOF
search ${INTERNAL_ZONE}
nameserver 127.0.0.1
nameserver ${ROUTER_GW}
EOF
    }

    verify() {
        info "Verifying resolver behaviour"

        # 1. Authoritative answer for the internal zone.
        local internal
        internal=$(getent ahostsv4 "dns.${INTERNAL_ZONE}" | awk 'NR==1{print $1}')
        [[ "$internal" == "$DNS_IP" ]] \
            || err "dns.${INTERNAL_ZONE} resolved to '${internal}', expected ${DNS_IP}"
        info "Internal zone OK: dns.${INTERNAL_ZONE} -> ${internal}"

        # 2. Recursion/forwarding for everything else.
        getent ahostsv4 example.com >/dev/null \
            || err "Forwarding to ${ROUTER_GW} is not working (example.com did not resolve)"
        info "Forwarding OK: external names resolve via ${ROUTER_GW}"

        systemctl is-enabled --quiet dns || err "dns.service is not enabled"
    }

    configure_apt_proxy
    disable_resolved
    install_packages
    install_technitium
    login
    secure_admin
    configure_forwarders
    create_zone
    create_api_token
    point_self_at_technitium
    verify

    cat <<EOF

================================================================
dns setup complete (${DNS_IP}).

Zone:       ${INTERNAL_ZONE} (authoritative, split-horizon)
Forwarders: ${ROUTER_GW} (everything outside the zone)
Web UI:     http://${DNS_IP}:5380  (admin)
API token:  /etc/dns-api-token

Point the router's DHCP DNS option at ${DNS_IP} to give the whole
LAN internal name resolution.

REMINDER: this server is authoritative for ${INTERNAL_ZONE}. Any public
${INTERNAL_ZONE} record you need from inside the LAN must be added here
too, or it will return NXDOMAIN internally.
================================================================
EOF
}

# ===================================================================
# Host-side
# ===================================================================

host_main() {
    source "$SCRIPT_DIR/lib/common.sh"
    [[ $EUID -eq 0 ]] || err "Run as root"

    local hostname="dns"
    local deploy_only=0
    [[ "${1:-}" == "--deploy-only" ]] && deploy_only=1

    [[ -n "${DNS_ADMIN_PASSWORD:-}" ]] \
        || err "Set DNS_ADMIN_PASSWORD before running (no default admin password is shipped)"

    local ctid ip
    if [[ $deploy_only -eq 1 ]]; then
        ctid=$(resolve_ctid "$hostname") || err "CT '$hostname' not found"
        ip="192.168.1.${ctid}"
    else
        # The DNS host is the bootstrap floor: everything else finds it by IP
        # before name resolution exists, so its CTID is pinned rather than
        # allocated dynamically like the other hosts.
        ctid="$DNS_CTID"
        ip="$DNS_IP"
        if create_lxc "$ctid" "$hostname" "$ip" 1024 2 8 "$ROUTER_GW" "no"; then
            pct set "$ctid" --onboot 1
            pct start "$ctid"
            info "CREATED: CT $ctid ($hostname) at $ip"
            sleep 10
        fi
    fi

    pct status "$ctid" | grep -q running || pct start "$ctid"

    info "Deploying $hostname configuration (CT $ctid)"
    pct push "$ctid" "$SCRIPT_DIR/05-setup-dns.sh" /root/05-setup-dns.sh --perms 0755
    pct exec "$ctid" -- bash -c "DEBIAN_FRONTEND=noninteractive TERM=dumb \
        INTERNAL_ZONE='${INTERNAL_ZONE}' ROUTER_GW='${ROUTER_GW}' \
        APT_CACHE_IP='${APT_CACHE_IP}' DNS_IP='${ip}' \
        DNS_ADMIN_PASSWORD='${DNS_ADMIN_PASSWORD}' \
        /root/05-setup-dns.sh --configure"
}

if [[ "${1:-}" == "--configure" ]]; then
    configure
else
    host_main "$@"
fi
