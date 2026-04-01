#!/usr/bin/env bash
# 15-setup-wol.sh -- Prepare wol host environment (dual-homed, client-facing)
#
# Runs on: wol-a (10.0.0.208) -- Debian 13 LXC (privileged, dual-homed)
# Run order: Step 14 (SPIRE Agent must already be running on this host)
#
# This script sets up the host environment for the wol connection interface
# (.NET 9). wol is a stateless service that handles telnet, TLS telnet,
# WebSocket, and WSS protocols on port 6969. It passes game traffic between
# clients and the wol-realm game engine, and calls API services (accounts,
# players, world) directly on the private network via mTLS.
#
# wol is designed for horizontal autoscaling: many instances can run
# simultaneously, each maintaining no state beyond its active client
# connections.
#
# Setup includes:
#   - Service user (UID 1006, GID 1006)
#   - .NET 9 runtime (not SDK, runtime only)
#   - Directory structure
#   - Compiled C wrapper binary at /usr/lib/wol/bin/start
#     (used by SPIRE unix:path workload attestor)
#   - Dual-homed networking: external interface locked to :6969 game clients,
#     internal interface for API/realm traffic via private network
#   - iptables rules on external interface (persistent via iptables-save)
#   - iptables rules on internal interface
#   - IPv6 disabled
#   - Environment/appsettings for API service addresses and realm
#   - Systemd service unit
#
# The SPIRE Agent (10-setup-spire-agent.sh) must be run on this host first.
# After this script: deploy the wol server binary and start the service.
#
# Usage:
#   WOL_NAME=wol-a WOL_IP=10.0.0.208 EXTERNAL_IF=eth0 INTERNAL_IF=eth1 \
#       ./19-setup-wol.sh

set -euo pipefail

_LIB="$(dirname "$0")/lib/common.sh"; [[ -f "$_LIB" ]] || _LIB="/root/lib/common.sh"; source "$_LIB" 2>/dev/null || true

# Boot-time secret scrub: remove leftover .env.bootstrap from prior failed runs
rm -f /root/.env.bootstrap

# ---------------------------------------------------------------------------
# Configuration (override via environment)
# ---------------------------------------------------------------------------

WOL_NAME="${WOL_NAME:-wol-a}"
WOL_IP="${WOL_IP:-10.0.0.208}"
EXTERNAL_IF="${EXTERNAL_IF:-eth0}"
INTERNAL_IF="${INTERNAL_IF:-eth1}"
GAME_PORT="${GAME_PORT:-6969}"
GW_A="10.0.0.200"
GW_B="10.0.0.201"

# API service addresses (direct mTLS, no gateway proxy)
ACCOUNTS_IP="10.0.0.207"
API_PORT="8443"

# Per-environment service addresses (prod and test)
REALM_PROD_IP="${REALM_PROD_IP:-10.0.0.210}"
REALM_TEST_IP="${REALM_TEST_IP:-10.0.0.215}"
WORLD_PROD_IP="${WORLD_PROD_IP:-10.0.0.211}"
WORLD_TEST_IP="${WORLD_TEST_IP:-10.0.0.216}"
AI_PROD_IP="${AI_PROD_IP:-10.0.0.212}"
AI_TEST_IP="${AI_TEST_IP:-10.0.0.217}"

WOL_USER="wol"
WOL_UID="1006"
WOL_GID="1006"
WOL_HOME="/var/lib/wol"
WOL_LIB="/usr/lib/wol"
WOL_ETC="/etc/wol"
WOL_LOG="/var/log/wol"
SPIRE_GROUP="spire"
SPIRE_SOCKET="/var/run/spire/agent.sock"

DOTNET_MAJOR="9"

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

[[ $EUID -eq 0 ]] || err "Run as root"

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

    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        curl ca-certificates iptables chrony \
        build-essential gcc \
        "$icu_pkg" libssl3
}

# ---------------------------------------------------------------------------
# .NET 9 runtime (via Microsoft APT repository, sourced from common.sh)
# ---------------------------------------------------------------------------

# Uses install_dotnet_runtime from lib/common.sh with aspnetcore runtime
# (Microsoft.Extensions packages pull in ASP.NET Core transitively)

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
        "$WOL_ETC/certs" \
        "$WOL_LOG"

    chown -R "$WOL_USER:$WOL_USER" "$WOL_LIB" "$WOL_HOME" "$WOL_ETC" "$WOL_LOG"
    chmod 750 "$WOL_ETC"
    chmod 750 "$WOL_ETC/certs"

    touch "$WOL_LOG/wol.log"
    chown "$WOL_USER:$WOL_USER" "$WOL_LOG/wol.log"
}

# ---------------------------------------------------------------------------
# Compiled wrapper binary (SPIRE unix:path workload attestor target)
#
# SPIRE registration entry: -selector unix:path:/usr/lib/wol/bin/start
# ---------------------------------------------------------------------------

compile_wrapper() {
    info "Compiling workload wrapper binary"
    local src="/tmp/wol-start.c"
    local bin="$WOL_LIB/bin/start"

    cat > "$src" <<'C_SOURCE'
/*
 * /usr/lib/wol/bin/start
 *
 * Workload wrapper for the wol connection interface (.NET 9).
 * This compiled binary is the unix:path selector for SPIRE workload attestation.
 * It execs into the .NET runtime with the published server DLL.
 *
 * Compile: gcc -O2 -Wall -o start start.c
 */
#include <unistd.h>
#include <stdio.h>

int main(void) {
    char *const argv[] = {
        "/usr/bin/dotnet",
        "/usr/lib/wol/app/Wol.Server.dll",
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
# Dual-homed networking: external interface lockdown
#
# The external interface accepts ONLY inbound game client connections on
# $GAME_PORT. No outbound connections can be initiated on it.
#
# Rules are persisted via iptables-save and restored on boot.
# ---------------------------------------------------------------------------

configure_external_interface() {
    info "Configuring external interface ($EXTERNAL_IF) lockdown via iptables"

    # Only accept game client connections on :$GAME_PORT on the external interface
    iptables -A INPUT -i "$EXTERNAL_IF" -p tcp --dport "$GAME_PORT" -j ACCEPT
    iptables -A INPUT -i "$EXTERNAL_IF" -m state --state ESTABLISHED,RELATED -j ACCEPT
    iptables -A INPUT -i "$EXTERNAL_IF" -j DROP

    # Only allow outbound traffic for established game connections on the external interface
    iptables -A OUTPUT -o "$EXTERNAL_IF" -m state --state ESTABLISHED,RELATED -j ACCEPT
    iptables -A OUTPUT -o "$EXTERNAL_IF" -j DROP

    info "External interface locked down: inbound :$GAME_PORT only, no outbound initiation"
}

# ---------------------------------------------------------------------------
# Internal interface routing
#
# The internal interface routes to the private network (10.0.0.0/24 + 10.0.1.0/24).
# Internet access (apt, certbot) goes through the gateways' NAT (ECMP).
# ---------------------------------------------------------------------------

configure_internal_routing() {
    info "Configuring internal interface ($INTERNAL_IF) routing"

    # Add lower-priority ECMP default route via both gateways for internal-originated
    # traffic (apt, certbot). The external interface's default route takes priority
    # for game client response traffic via ESTABLISHED,RELATED.
    # Do not use "dev $INTERNAL_IF" with nexthop: the kernel resolves the device from
    # the gateway IP, and specifying dev explicitly causes RTA_OIF mismatch errors.
    ip route del default metric 200 2>/dev/null || true
    ip route add default metric 200 \
        nexthop via "$GW_A" nexthop via "$GW_B"
    info "ECMP default route set via $GW_A and $GW_B (metric 200)"

    # Persist the route via a post-up hook (does not redefine the interface,
    # which is managed by LXC/Proxmox)
    local hook_file="/etc/networkd-dispatcher/routable.d/50-wol-gateway-route"
    mkdir -p /etc/networkd-dispatcher/routable.d
    cat > "$hook_file" <<HOOK
#!/bin/bash
# Add ECMP gateway route when the internal interface comes up
if [[ "\$IFACE" == "$INTERNAL_IF" ]]; then
    ip route add default metric 200 \
        nexthop via $GW_A nexthop via $GW_B 2>/dev/null || true
fi
HOOK
    chmod 755 "$hook_file"
    info "Persistent route hook written to $hook_file"
}

# ---------------------------------------------------------------------------
# DNS and NTP via both gateways (on internal interface)
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
# Internal interface firewall (iptables)
#
# Manages the private network interface. External interface is managed
# separately by configure_external_interface() above.
# ---------------------------------------------------------------------------

configure_internal_firewall() {
    info "Configuring internal interface ($INTERNAL_IF) firewall via iptables"

    # Set default policies
    iptables -P INPUT DROP
    iptables -P OUTPUT ACCEPT

    # Allow established/related and loopback
    iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    iptables -A INPUT -i lo -j ACCEPT

    # SSH from private network
    iptables -A INPUT -s 10.0.0.0/24 -p tcp --dport 22 -j ACCEPT
    iptables -A INPUT -s 10.0.1.0/24 -p tcp --dport 22 -j ACCEPT

    # Game port on internal interfaces (health probes from obs, gateway forwarding)
    iptables -A INPUT -p tcp --dport "$GAME_PORT" -j ACCEPT

    # Persist rules (including external interface rules set earlier)
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4

    # Restore on boot via a systemd oneshot
    if [[ ! -f /etc/systemd/system/iptables-restore.service ]]; then
        cat > /etc/systemd/system/iptables-restore.service <<'UNIT'
[Unit]
Description=Restore iptables rules
Before=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=/sbin/iptables-restore /etc/iptables/rules.v4

[Install]
WantedBy=multi-user.target
UNIT
        systemctl daemon-reload
        systemctl enable iptables-restore
    fi
    info "Internal firewall configured"
}


# ---------------------------------------------------------------------------
# appsettings.json
# ---------------------------------------------------------------------------

write_appsettings() {
    info "Writing production appsettings.json"
    # The wol server loads appsettings.json from AppContext.BaseDirectory (the app
    # directory), so the production config must live alongside the deployed binary.
    local settings_file="$WOL_LIB/app/appsettings.json"

    if [[ -f "$settings_file" ]]; then
        info "appsettings already exists; skipping"
        return
    fi

    cat > "$settings_file" <<EOF
{
  "Network": {
    "Port": $GAME_PORT,
    "TlsCertPath": "$WOL_ETC/certs/server.crt",
    "TlsKeyPath": "$WOL_ETC/certs/server.key",
    "SniffTimeoutMs": 1000
  },
  "Logging": {
    "LogLevel": {
      "Default": "Information",
      "Wol.Server": "Information"
    }
  }
}
EOF

    chown "$WOL_USER:$WOL_USER" "$settings_file"
    chmod 640 "$settings_file"
    info "appsettings written to $settings_file"
}

# ---------------------------------------------------------------------------
# Environment file
# ---------------------------------------------------------------------------

write_env_file() {
    info "Writing environment file"
    local env_file="$WOL_ETC/wol.env"

    if [[ -f "$env_file" ]]; then
        info "Env file already exists; skipping"
        return
    fi

    cat > "$env_file" <<EOF
# wol environment configuration

# .NET runtime
DOTNET_ROOT=$DOTNET_ROOT

# SPIRE Workload API socket
SPIFFE_ENDPOINT_SOCKET=unix://$SPIRE_SOCKET
SPIFFE_TRUST_DOMAIN=spiffe://wol

# API services (direct mTLS on private network)
WOL_ACCOUNTS_URL=https://$ACCOUNTS_IP:$API_PORT

# Per-environment service addresses (realm routing selects at login)
WOL_REALM_PROD_HOST=$REALM_PROD_IP
WOL_REALM_TEST_HOST=$REALM_TEST_IP
WOL_WORLD_PROD_URL=https://$WORLD_PROD_IP:$API_PORT
WOL_WORLD_TEST_URL=https://$WORLD_TEST_IP:$API_PORT
WOL_AI_PROD_URL=https://$AI_PROD_IP:$API_PORT
WOL_AI_TEST_URL=https://$AI_TEST_IP:$API_PORT
EOF

    chown "root:$WOL_USER" "$env_file"
    chmod 640 "$env_file"
    info "Env file written to $env_file"
}

# ---------------------------------------------------------------------------
# Systemd service unit
# ---------------------------------------------------------------------------

write_systemd_unit() {
    info "Writing wol systemd unit"
    cat > /etc/systemd/system/wol.service <<EOF
[Unit]
Description=WOL Connection Interface ($WOL_NAME)
After=network-online.target spire-agent.service
Wants=network-online.target
Requires=spire-agent.service

[Service]
Type=simple
User=${WOL_USER}
Group=${WOL_USER}
EnvironmentFile=${WOL_ETC}/wol.env
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
StandardOutput=append:${WOL_LOG}/wol.log
StandardError=append:${WOL_LOG}/wol.log

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    info "Systemd unit written. Service will NOT start until server binary is deployed."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    info "Setting up wol instance: $WOL_NAME ($WOL_IP)"
    info "External interface: $EXTERNAL_IF (game clients on :$GAME_PORT)"
    info "Internal interface: $INTERNAL_IF (private network, API + realm)"

    disable_ipv6
    install_packages
    install_dotnet_runtime "$DOTNET_MAJOR.0" "aspnetcore"
    setup_user
    setup_directories
    compile_wrapper
    configure_internal_routing
    configure_dns_ntp
    configure_internal_firewall
    configure_external_interface
    write_appsettings
    write_env_file
    write_systemd_unit

    cat <<EOF

================================================================
$WOL_NAME host environment is ready.

Wrapper binary:     $WOL_LIB/bin/start
.NET runtime:       $DOTNET_ROOT
App directory:      $WOL_LIB/app
SPIRE socket:       $SPIRE_SOCKET
Env file:           $WOL_ETC/wol.env
appsettings:        $WOL_LIB/app/appsettings.json
Log dir:            $WOL_LOG

External interface: $EXTERNAL_IF
  - Inbound :$GAME_PORT only (game clients)
  - No outbound initiation
Internal interface: $INTERNAL_IF
  - Private network (10.0.0.0/24 + 10.0.1.0/24)
  - API services: direct mTLS
  - Internet via gateway NAT (ECMP: $GW_A + $GW_B, metric 200)

Host environment ready. Service deployment is handled separately.
================================================================
EOF
}

main "$@"
