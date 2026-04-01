#!/usr/bin/env bash
# 14-setup-wol-realm.sh -- Prepare wol-realm host environment
#
# Runs on: wol-realm-{prod,test} -- Debian 13 LXC (privileged)
# Run order: Step 13 (SPIRE Agent must already be running on this host)
#
# This script sets up the host environment for the wol-realm game engine (.NET 9):
#   - Service user (UID 1001, GID 1001)
#   - .NET 9 runtime (not SDK, runtime only)
#   - Directory structure
#   - Compiled C wrapper binary at /usr/lib/wol-realm/bin/start
#     (used by SPIRE unix:path workload attestor)
#   - Default route, DNS, and NTP via both gateways (ECMP)
#   - iptables firewall (SSH + wol connections from private network)
#   - IPv6 disabled
#   - Environment file and systemd service unit
#
# wol-realm is an internal-only service on the private network. It has no
# external interface. wol instances connect to it to relay game traffic.
#
# The SPIRE Agent (09-setup-spire-agent.sh) must be run on this host first.
# After this script: deploy the wol-realm binary and start the service.
#
# Usage:
#   REALM_NAME=wol-realm-prod REALM_IP=10.0.0.210 ./14-setup-wol-realm.sh
#   REALM_NAME=wol-realm-test REALM_IP=10.0.0.215 ./14-setup-wol-realm.sh

set -euo pipefail

_LIB="$(dirname "$0")/lib/common.sh"; [[ -f "$_LIB" ]] || _LIB="/root/lib/common.sh"; source "$_LIB" 2>/dev/null || true

# Boot-time secret scrub: remove leftover .env.bootstrap from prior failed runs
rm -f /root/.env.bootstrap

# ---------------------------------------------------------------------------
# Configuration (override via environment)
# ---------------------------------------------------------------------------

REALM_NAME="${REALM_NAME:?Set REALM_NAME (e.g. wol-realm-prod or wol-realm-test)}"
REALM_IP="${REALM_IP:?Set REALM_IP (e.g. 10.0.0.210 for prod, 10.0.0.215 for test)}"
GW_A="10.0.0.200"
GW_B="10.0.0.201"

WOL_USER="wol-realm"
WOL_UID="1001"
WOL_GID="1001"
WOL_HOME="/var/lib/wol-realm"
WOL_LIB="/usr/lib/wol-realm"
WOL_ETC="/etc/wol-realm"
WOL_LOG="/var/log/wol-realm"
SPIRE_GROUP="spire"
SPIRE_SOCKET="/var/run/spire/agent.sock"

DOTNET_MAJOR="9"

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

[[ $EUID -eq 0 ]] || err "Run as root"

# ---------------------------------------------------------------------------
# Gateway route (must be first so apt can reach the internet)
# ---------------------------------------------------------------------------

configure_gateway_route() {
    info "Configuring ECMP default route via both gateways"
    if ip route show | grep -q "default"; then
        ip route del default 2>/dev/null || true
    fi
    ip route add default nexthop via "$GW_A" nexthop via "$GW_B"
    info "ECMP default route set via $GW_A and $GW_B"
}

# ---------------------------------------------------------------------------
# DNS and NTP via both gateways
# ---------------------------------------------------------------------------

configure_dns_ntp() {
    cat > /etc/resolv.conf <<EOF
nameserver $GW_A
nameserver $GW_B
search wol.local
EOF
    info "DNS resolvers set to $GW_A and $GW_B"

    if command -v chronyc &>/dev/null || [[ -f /etc/chrony/chrony.conf ]]; then
        cat > /etc/chrony/chrony.conf <<EOF
server $GW_A iburst
server $GW_B iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
EOF
        systemctl restart chrony 2>/dev/null || true
        info "NTP set to $GW_A and $GW_B"
    fi
}

# ---------------------------------------------------------------------------
# Disable IPv6
# ---------------------------------------------------------------------------

disable_ipv6() {
    info "Disabling IPv6"
    cat > /etc/sysctl.d/99-disable-ipv6.conf <<EOF
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF
    sysctl -p /etc/sysctl.d/99-disable-ipv6.conf
}

# ---------------------------------------------------------------------------
# Packages
# ---------------------------------------------------------------------------

install_packages() {
    info "Installing packages"
    apt-get update -qq

    # libicu package name includes the soname version (libicu72 on Debian 13,
    # libicu74 on Debian 13, etc.). Detect the available version.
    local icu_pkg
    icu_pkg=$(apt-cache search '^libicu[0-9]+$' | awk '{print $1}' | sort -V | tail -1)
    [[ -n "$icu_pkg" ]] || err "No libicu package found"

    apt-get install -y --no-install-recommends \
        curl ca-certificates iptables chrony \
        build-essential gcc \
        "$icu_pkg" libssl3
}

# ---------------------------------------------------------------------------
# .NET 9 runtime (via Microsoft APT repository, sourced from common.sh)
# ---------------------------------------------------------------------------

# Uses install_dotnet_runtime from lib/common.sh (aspnetcore runtime)

# ---------------------------------------------------------------------------
# Service user and group
# ---------------------------------------------------------------------------

setup_user() {
    info "Creating $WOL_USER user (UID $WOL_UID)"
    getent group "$WOL_GID" &>/dev/null || groupadd --gid "$WOL_GID" "$WOL_USER"
    id -u "$WOL_USER" &>/dev/null || useradd \
        --uid "$WOL_UID" \
        --gid "$WOL_GID" \
        --no-create-home \
        --home-dir "$WOL_HOME" \
        --shell /usr/sbin/nologin \
        "$WOL_USER"

    usermod -aG "$SPIRE_GROUP" "$WOL_USER"
    info "Added $WOL_USER to $SPIRE_GROUP group"
}

# ---------------------------------------------------------------------------
# Directory structure
# ---------------------------------------------------------------------------

setup_directories() {
    info "Creating directory structure"
    mkdir -p \
        "$WOL_LIB/bin" \
        "$WOL_LIB/app" \
        "$WOL_HOME" \
        "$WOL_ETC" \
        "$WOL_LOG"

    chown -R "$WOL_USER:$WOL_USER" "$WOL_LIB" "$WOL_HOME" "$WOL_ETC" "$WOL_LOG"
    chmod 750 "$WOL_ETC"

    # Pre-create log file so systemd's StandardOutput=append: doesn't create it as root
    touch "$WOL_LOG/wol-realm.log"
    chown "$WOL_USER:$WOL_USER" "$WOL_LOG/wol-realm.log"
}

# ---------------------------------------------------------------------------
# Compiled wrapper binary (SPIRE unix:path workload attestor target)
#
# SPIRE registration entry: -selector unix:path:/usr/lib/wol-realm/bin/start
# ---------------------------------------------------------------------------

compile_wrapper() {
    info "Compiling workload wrapper binary"
    local src="/tmp/wol-realm-start.c"
    local bin="$WOL_LIB/bin/start"

    cat > "$src" <<'C_SOURCE'
/*
 * /usr/lib/wol-realm/bin/start
 *
 * Workload wrapper for the wol-realm game engine (.NET 9).
 * This compiled binary is the unix:path selector for SPIRE workload attestation.
 * It execs into the .NET runtime with the published realm DLL.
 *
 * Compile: gcc -O2 -Wall -o start start.c
 */
#include <unistd.h>
#include <stdio.h>

int main(void) {
    char *const argv[] = {
        "/usr/bin/dotnet",
        "/usr/lib/wol-realm/app/Wol.Realm.dll",
        NULL
    };
    execv(argv[0], argv);
    perror("execv failed");
    return 1;
}
C_SOURCE

    gcc -O2 -Wall -o "$bin" "$src"
    chown root:root "$bin"
    chmod 755 "$bin"
    rm -f "$src"
    info "Wrapper compiled: $bin"
}

# ---------------------------------------------------------------------------
# Firewall (iptables, single-homed internal service)
# ---------------------------------------------------------------------------

configure_firewall() {
    info "Configuring firewall (iptables)"
    iptables -F INPUT 2>/dev/null || true
    iptables -P INPUT DROP
    iptables -P OUTPUT ACCEPT
    iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    iptables -A INPUT -i lo -j ACCEPT

    # SSH from private network
    iptables -A INPUT -s 10.0.0.0/24 -p tcp --dport 22 -j ACCEPT
    iptables -A INPUT -s 10.0.1.0/24 -p tcp --dport 22 -j ACCEPT

    # Persist rules
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4
    info "Firewall configured"
}

# ---------------------------------------------------------------------------
# Environment file
# ---------------------------------------------------------------------------

write_env_file() {
    info "Writing environment file"
    local env_file="$WOL_ETC/wol-realm.env"

    if [[ -f "$env_file" ]]; then
        info "Env file already exists; skipping"
        return
    fi

    cat > "$env_file" <<EOF
# wol-realm environment configuration

# .NET runtime
DOTNET_ROOT=$DOTNET_ROOT

# SPIRE Workload API socket
SPIFFE_ENDPOINT_SOCKET=unix://$SPIRE_SOCKET
SPIFFE_TRUST_DOMAIN=spiffe://wol
EOF

    chown "root:$WOL_USER" "$env_file"
    chmod 640 "$env_file"
    info "Env file written to $env_file"
}

# ---------------------------------------------------------------------------
# Systemd service unit
# ---------------------------------------------------------------------------

write_systemd_unit() {
    info "Writing wol-realm systemd unit"
    cat > /etc/systemd/system/wol-realm.service <<EOF
[Unit]
Description=WOL Game Engine ($REALM_NAME)
After=network-online.target spire-agent.service
Wants=network-online.target
Requires=spire-agent.service

[Service]
Type=simple
User=${WOL_USER}
Group=${WOL_USER}
EnvironmentFile=${WOL_ETC}/wol-realm.env
WorkingDirectory=${WOL_LIB}/app
ExecStart=${WOL_LIB}/bin/start
Restart=always
RestartSec=5
LimitNOFILE=65536
LimitCORE=0
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=${WOL_HOME} ${WOL_LOG}
StandardOutput=append:${WOL_LOG}/wol-realm.log
StandardError=append:${WOL_LOG}/wol-realm.log

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    info "Systemd unit written. Service will NOT start until realm binary is deployed."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    info "Setting up realm: $REALM_NAME ($REALM_IP)"

    configure_gateway_route
    configure_dns_ntp
    disable_ipv6
    install_packages
    install_dotnet_runtime "$DOTNET_MAJOR.0" "aspnetcore"
    setup_user
    setup_directories
    compile_wrapper
    configure_firewall
    write_env_file
    write_systemd_unit

    cat <<EOF

================================================================
$REALM_NAME host environment is ready.

Wrapper binary:     $WOL_LIB/bin/start
.NET runtime:       $DOTNET_ROOT
App directory:      $WOL_LIB/app
SPIRE socket:       $SPIRE_SOCKET
Env file:           $WOL_ETC/wol-realm.env
Log dir:            $WOL_LOG

Single-homed: private network only (10.0.0.0/24 + 10.0.1.0/24)
Default route: ECMP via $GW_A and $GW_B

Host environment ready. Service deployment is handled separately.
================================================================
EOF
}

main "$@"
