#!/usr/bin/env bash
# 09-setup-spire-agent.sh -- Install and start SPIRE Agent on a service host
#
# Runs on: wol-accounts (10.0.0.207), and future wol-realm-* hosts
# Run order: Step 08 (SPIRE Server must be running)
#
# Usage:
#   JOIN_TOKEN=<token> HOSTNAME_OVERRIDE=<hostname> ./10-setup-spire-agent.sh
#
# Generate a join token on spire-server before running:
#   spire-server token generate -spiffeID spiffe://wol/node/<hostname> -ttl 300
#
# The token is single-use with a 5-minute TTL. On subsequent reboots,
# the agent re-attests from its cached state without a new token.

set -euo pipefail

# Boot-time secret scrub: remove leftover .env.bootstrap from prior failed runs
_LIB="$(dirname "$0")/lib/common.sh"; [[ -f "$_LIB" ]] || _LIB="/root/lib/common.sh"; source "$_LIB" 2>/dev/null || true
rm -f /root/.env.bootstrap

SPIRE_VERSION="1.10.3"
# SPIRE server is dual-homed: 10.0.0.204 (prod) and 10.0.1.204 (test).
# Use the IP reachable from this host's network.
if [[ "$(hostname -I 2>/dev/null | awk '{print $1}')" == 10.0.1.* ]]; then
    SPIRE_SERVER_IP="10.0.1.204"
else
    SPIRE_SERVER_IP="10.0.0.204"
fi
SPIRE_SERVER_PORT="8081"
TRUST_DOMAIN="wol"
SPIRE_USER="spire"
SPIRE_GROUP="spire"
SPIRE_CONF_DIR="/etc/spire/agent"
SPIRE_DATA_DIR="/var/lib/spire/agent"
SPIRE_SOCKET_DIR="/var/run/spire"
SPIRE_BIN_DIR="/usr/local/bin"
LOG_DIR="/var/log/spire"

# Read join token from env var or from file (written by pve-deploy.sh)
if [[ -z "${JOIN_TOKEN:-}" && -f /var/lib/spire/agent/join_token ]]; then
    JOIN_TOKEN=$(cat /var/lib/spire/agent/join_token)
fi
: "${JOIN_TOKEN:?Set JOIN_TOKEN to the token from: spire-server token generate}"
THIS_HOSTNAME="${HOSTNAME_OVERRIDE:-$(hostname -s)}"

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

[[ $EUID -eq 0 ]] || err "Run as root"

# ---------------------------------------------------------------------------
# Packages + SPIRE binary
# ---------------------------------------------------------------------------

install_packages() {
    info "Installing packages"
    apt-get update -qq
    apt-get install -y --no-install-recommends curl ca-certificates iptables
}

install_spire_agent() {
    if [[ -x "$SPIRE_BIN_DIR/spire-agent" ]]; then
        info "spire-agent already installed; skipping download"
        return
    fi
    info "Installing SPIRE agent $SPIRE_VERSION"
    local tarball="spire-${SPIRE_VERSION}-linux-amd64-musl.tar.gz"
    local url="https://github.com/spiffe/spire/releases/download/v${SPIRE_VERSION}/${tarball}"
    local tmp="/tmp/spire-install"
    mkdir -p "$tmp"
    curl -fsSL --connect-timeout 30 --retry 3 --retry-delay 5 "$url" -o "/tmp/${tarball}"
    tar -xzf "/tmp/${tarball}" -C "$tmp"
    rm -f "/tmp/${tarball}"
    cp "$tmp/spire-${SPIRE_VERSION}/bin/spire-agent" "$SPIRE_BIN_DIR/"
    chmod 755 "$SPIRE_BIN_DIR/spire-agent"
    rm -rf "$tmp"
}

# ---------------------------------------------------------------------------
# User, group, and directories
# ---------------------------------------------------------------------------

setup_user_and_dirs() {
    info "Creating spire group and directories"

    # spire group: service users are added to this group to access the agent socket
    getent group "$SPIRE_GROUP" &>/dev/null || groupadd --system "$SPIRE_GROUP"

    # spire system user (runs the agent)
    id -u "$SPIRE_USER" &>/dev/null || useradd \
        --system --no-create-home \
        --home-dir "$SPIRE_DATA_DIR" \
        --shell /usr/sbin/nologin \
        --gid "$SPIRE_GROUP" \
        "$SPIRE_USER"

    mkdir -p "$SPIRE_CONF_DIR" "$SPIRE_DATA_DIR" "$SPIRE_SOCKET_DIR" "$LOG_DIR"

    # Socket dir: accessible by spire group (service users are members)
    chown "root:$SPIRE_GROUP" "$SPIRE_SOCKET_DIR"
    chmod 770 "$SPIRE_SOCKET_DIR"

    # Data dir: spire user only (cached SVIDs)
    chown -R "$SPIRE_USER:$SPIRE_USER" "$SPIRE_DATA_DIR" "$SPIRE_CONF_DIR" "$LOG_DIR"
    chmod 700 "$SPIRE_DATA_DIR"

    # Pre-create log file so systemd's StandardOutput=append: doesn't create it as root
    touch "$LOG_DIR/agent.log"
    chown "$SPIRE_USER:$SPIRE_USER" "$LOG_DIR/agent.log"
}

# ---------------------------------------------------------------------------
# Place root CA cert
# ---------------------------------------------------------------------------

check_root_ca() {
    # Copy from the WOL CA store (distributed by pve-root-ca.sh) if not already present
    if [[ ! -f "$SPIRE_CONF_DIR/root_ca.crt" ]]; then
        local wol_cert="/etc/ssl/wol/root_ca.crt"
        if [[ -f "$wol_cert" ]]; then
            cp "$wol_cert" "$SPIRE_CONF_DIR/root_ca.crt"
            chown "$SPIRE_USER:$SPIRE_GROUP" "$SPIRE_CONF_DIR/root_ca.crt"
            info "Copied root CA from $wol_cert"
        else
            err "Missing root CA cert. Expected at $wol_cert or $SPIRE_CONF_DIR/root_ca.crt"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Agent configuration
# ---------------------------------------------------------------------------

write_agent_config() {
    info "Writing agent.conf for host: $THIS_HOSTNAME"
    cat > "$SPIRE_CONF_DIR/agent.conf" <<EOF
agent {
    data_dir     = "$SPIRE_DATA_DIR"
    log_level    = "INFO"
    log_file     = "$LOG_DIR/agent.log"

    server_address = "$SPIRE_SERVER_IP"
    server_port    = "$SPIRE_SERVER_PORT"

    socket_path = "$SPIRE_SOCKET_DIR/agent.sock"

    trust_domain      = "$TRUST_DOMAIN"
    trust_bundle_path = "$SPIRE_CONF_DIR/root_ca.crt"
    insecure_bootstrap = false

    join_token = "$JOIN_TOKEN"
}

plugins {
    NodeAttestor "join_token" {
        plugin_data {}
    }

    WorkloadAttestor "unix" {
        plugin_data {}
    }

    KeyManager "memory" {
        plugin_data {}
    }
}

health_checks {
    listener_enabled = true
    bind_address     = "0.0.0.0"
    bind_port        = "8082"
    live_path        = "/live"
    ready_path       = "/ready"
}
EOF
    chown "$SPIRE_USER:$SPIRE_USER" "$SPIRE_CONF_DIR/agent.conf"
    chmod 640 "$SPIRE_CONF_DIR/agent.conf"
}

# ---------------------------------------------------------------------------
# Systemd unit
# ---------------------------------------------------------------------------

write_systemd_unit() {
    info "Writing systemd unit for SPIRE Agent"
    cat > /etc/systemd/system/spire-agent.service <<EOF
[Unit]
Description=SPIRE Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SPIRE_USER}
Group=${SPIRE_GROUP}
ExecStart=${SPIRE_BIN_DIR}/spire-agent run -config ${SPIRE_CONF_DIR}/agent.conf
Restart=always
RestartSec=5
LimitNOFILE=65536
LimitCORE=0
NoNewPrivileges=true
RuntimeDirectory=spire
RuntimeDirectoryMode=0770
RuntimeDirectoryGroup=${SPIRE_GROUP}
StandardOutput=append:${LOG_DIR}/agent.log
StandardError=append:${LOG_DIR}/agent.log

[Install]
WantedBy=multi-user.target
EOF
}

# ---------------------------------------------------------------------------
# Start and verify
# ---------------------------------------------------------------------------

start_and_verify() {
    systemctl daemon-reload
    systemctl enable --now spire-agent

    info "Waiting for SPIRE Agent to attest and become healthy..."
    local i=0
    until curl -sf "http://localhost:8082/live" &>/dev/null; do
        sleep 2
        (( i++ )) && (( i >= 30 )) && err "SPIRE Agent did not become healthy in 60s; check $LOG_DIR/agent.log"
    done
    info "SPIRE Agent is healthy"

    # Agent has successfully attested. Remove the join token from agent.conf.
    # The token is single-use and already consumed; keeping it on disk serves no purpose.
    sed -i '/^\s*join_token\s*=/d' "$SPIRE_CONF_DIR/agent.conf"
    info "Join token removed from agent.conf"

    info "Socket: $SPIRE_SOCKET_DIR/agent.sock"
    info "SPIFFE node ID: spiffe://$TRUST_DOMAIN/node/$THIS_HOSTNAME"
}

# ---------------------------------------------------------------------------
# Disable IPv6 (prevent egress bypass of IPv4 NAT/firewall)
# ---------------------------------------------------------------------------

disable_ipv6() {
    info "Disabling IPv6"
    cat > /etc/sysctl.d/99-disable-ipv6.conf <<SYSCTL
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
SYSCTL
    sysctl -p /etc/sysctl.d/99-disable-ipv6.conf
}

# ---------------------------------------------------------------------------
# Default route via gateway (internet access for apt, certbot, etc.)
# ---------------------------------------------------------------------------

configure_gateway_route() {
    configure_ecmp_route
}

# ---------------------------------------------------------------------------
# DNS and NTP client (use both gateways, auto-detected from lib/common.sh)
# ---------------------------------------------------------------------------

configure_dns_ntp() {
    configure_dns

    configure_ntp
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    disable_ipv6
    configure_gateway_route
    configure_dns_ntp
    install_packages
    install_spire_agent
    setup_user_and_dirs
    check_root_ca
    write_agent_config
    write_systemd_unit
    start_and_verify

    cat <<EOF

================================================================
SPIRE Agent running on $THIS_HOSTNAME
Node SPIFFE ID: spiffe://$TRUST_DOMAIN/node/$THIS_HOSTNAME

Next: run 12-register-workload-entries.sh on spire-server once
      all agents are running and node IDs are confirmed.
================================================================
EOF
}

main "$@"
