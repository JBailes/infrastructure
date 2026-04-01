#!/usr/bin/env bash
# 16-setup-wol-ai.sh -- Prepare wol-ai host environment
#
# Runs on: wol-ai-{prod,test} -- Debian 13 LXC (privileged)
# Run order: Step 15 (SPIRE Agent must already be running on this host)
#
# This script sets up the host environment for the wol-ai C#/.NET service:
#   - Service user (UID 1005, GID 1005)
#   - .NET 9 runtime
#   - Directory structure for published .NET binary
#   - SPIRE unix:path selector points directly to published executable
#   - Prompt template directory
#   - Systemd service unit (placeholder until service code is deployed)
#
# wol-ai has no database. It makes outbound HTTPS calls to external AI APIs
# through the gateways' NAT. API keys are stored in /etc/wol-ai/secrets/.
#
# The SPIRE Agent must be running on this host first.
# After this script: deploy the published .NET binary and run `systemctl start wol-ai`.

set -euo pipefail

_LIB="$(dirname "$0")/lib/common.sh"; [[ -f "$_LIB" ]] || _LIB="/root/lib/common.sh"; source "$_LIB" 2>/dev/null || true

# Boot-time secret scrub: remove leftover .env.bootstrap from prior failed runs
rm -f /root/.env.bootstrap

WOL_USER="wol-ai"
WOL_UID="1005"
WOL_GID="1005"
WOL_HOME="/var/lib/wol-ai"
WOL_LIB="/usr/lib/wol-ai"
WOL_ETC="/etc/wol-ai"
WOL_LOG="/var/log/wol-ai"
WOL_BIN="$WOL_LIB/Wol.Ai"
SPIRE_GROUP="spire"
SPIRE_SOCKET="/var/run/spire/agent.sock"
API_PORT="8443"

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

[[ $EUID -eq 0 ]] || err "Run as root"

# ---------------------------------------------------------------------------
# Packages
# ---------------------------------------------------------------------------

install_packages() {
    info "Installing packages"
    apt-get update -qq
    apt-get install -y --no-install-recommends \
        curl ca-certificates iptables chrony

    # .NET 9 ASP.NET Core runtime (for running published binaries)
    install_dotnet_runtime
}

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
        "$WOL_LIB" \
        "$WOL_HOME" \
        "$WOL_ETC/secrets" \
        "$WOL_ETC/prompts" \
        "$WOL_LOG"

    chown -R "$WOL_USER:$WOL_USER" "$WOL_LIB" "$WOL_HOME" "$WOL_LOG"
    chown root:"$WOL_USER" "$WOL_ETC" "$WOL_ETC/secrets" "$WOL_ETC/prompts"
    chmod 750 "$WOL_ETC"
    chmod 700 "$WOL_ETC/secrets"
    chmod 750 "$WOL_ETC/prompts"
}

# ---------------------------------------------------------------------------
# Environment file
# ---------------------------------------------------------------------------

write_env_file() {
    info "Writing environment file template"
    local env_file="$WOL_ETC/wol-ai.env"

    if [[ -f "$env_file" ]]; then
        info "Env file already exists; skipping"
        return
    fi

    cat > "$env_file" <<EOF
# wol-ai environment configuration

# SPIRE Workload API socket
SPIFFE_ENDPOINT_SOCKET=unix://$SPIRE_SOCKET
SPIFFE_TRUST_DOMAIN=spiffe://wol

# AI provider API key (stored in secrets dir, loaded by service)
AI_API_KEY_FILE=$WOL_ETC/secrets/api_key

# Prompt template directory
PROMPT_TEMPLATE_DIR=$WOL_ETC/prompts

# Rate limiting (per caller SPIFFE ID)
RATE_LIMIT_PER_CALLER_RPM=60
EOF

    chown "root:$WOL_USER" "$env_file"
    chmod 640 "$env_file"
    info "Env file written to $env_file"
}

# ---------------------------------------------------------------------------
# Systemd unit
# ---------------------------------------------------------------------------

write_systemd_unit() {
    info "Writing wol-ai systemd unit"
    cat > /etc/systemd/system/wol-ai.service <<EOF
[Unit]
Description=WOL AI Service
After=network-online.target spire-agent.service
Wants=network-online.target
Requires=spire-agent.service

[Service]
Type=exec
User=${WOL_USER}
Group=${WOL_USER}
EnvironmentFile=${WOL_ETC}/wol-ai.env
WorkingDirectory=${WOL_LIB}
ExecStart=${WOL_BIN}
Restart=always
RestartSec=2
LimitNOFILE=65536
LimitCORE=0
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=${WOL_HOME} ${WOL_LOG}
StandardOutput=journal
StandardError=journal
SyslogIdentifier=wol-ai

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    info "Systemd unit written. Service will NOT start until .NET binary is deployed."
}

# ---------------------------------------------------------------------------
# Network and firewall
# ---------------------------------------------------------------------------

disable_ipv6() {
    info "Disabling IPv6"
    cat > /etc/sysctl.d/99-disable-ipv6.conf <<SYSCTL
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
SYSCTL
    sysctl -p /etc/sysctl.d/99-disable-ipv6.conf
}

configure_gateway_route() {
    configure_ecmp_route
}

configure_dns_ntp() {
    configure_dns
    configure_ntp
}

configure_firewall() {
    info "Configuring firewall (iptables)"
    iptables -F INPUT 2>/dev/null || true
    iptables -P INPUT DROP
    iptables -P OUTPUT ACCEPT
    iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    iptables -A INPUT -i lo -j ACCEPT
    iptables -A INPUT -s 10.0.0.0/24 -p tcp --dport 22 -j ACCEPT
    iptables -A INPUT -s 10.0.1.0/24 -p tcp --dport 22 -j ACCEPT
    iptables -A INPUT -s 10.0.0.0/24 -p tcp --dport "$API_PORT" -j ACCEPT
    iptables -A INPUT -s 10.0.1.0/24 -p tcp --dport "$API_PORT" -j ACCEPT
    # Persist rules
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4
    info "Firewall enabled (iptables)"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    disable_ipv6
    configure_gateway_route
    configure_dns_ntp
    install_packages
    setup_user
    setup_directories
    write_env_file
    write_systemd_unit
    configure_firewall

    cat <<EOF

================================================================
wol-ai host environment is ready.

.NET binary path: $WOL_BIN
SPIRE socket:     $SPIRE_SOCKET
Env file:         $WOL_ETC/wol-ai.env
Secrets dir:      $WOL_ETC/secrets/ (add API key file before starting)
Prompts dir:      $WOL_ETC/prompts/ (add prompt templates)

Host environment ready. Service deployment is handled separately.
SPIRE registration is automated by step 12.
AI API key and prompt templates must be added before starting.
================================================================
EOF
}

main "$@"
