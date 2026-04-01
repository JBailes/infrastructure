#!/usr/bin/env bash
# 20-setup-wol-ai-prod.sh -- Prepare wol-ai-prod host environment
#
# Runs on: wol-ai-prod (10.0.0.212) -- Debian 13 LXC (privileged)
# Run order: Step 15 (SPIRE Agent must already be running on this host)

set -euo pipefail
_LIB="$(dirname "$0")/../lib/common.sh"; [[ -f "$_LIB" ]] || _LIB="/root/lib/common.sh"; source "$_LIB"
scrub_bootstrap_secrets

WOL_USER="wol-ai"
WOL_UID="1005"
WOL_GID="1005"
WOL_HOME="/var/lib/wol-ai"
WOL_LIB="/usr/lib/wol-ai"
WOL_ETC="/etc/wol-ai"
WOL_LOG="/var/log/wol-ai"
WOL_BIN="$WOL_LIB/Wol.Ai"
SPIRE_SOCKET="/var/run/spire/agent.sock"
API_PORT="8443"

[[ $EUID -eq 0 ]] || err "Run as root"

install_packages() {
    info "Installing packages"
    apt-get update -qq
    apt-get install -y --no-install-recommends curl ca-certificates iptables chrony
    install_dotnet_runtime
}

setup_user() {
    create_service_user "$WOL_USER" "$WOL_UID" "$WOL_GID" "$WOL_HOME"
    add_to_spire_group "$WOL_USER"
}

setup_directories() {
    info "Creating directory structure"
    mkdir -p "$WOL_LIB" "$WOL_HOME" "$WOL_ETC/secrets" "$WOL_ETC/prompts" "$WOL_LOG"
    chown -R "$WOL_USER:$WOL_USER" "$WOL_LIB" "$WOL_HOME" "$WOL_LOG"
    chown root:"$WOL_USER" "$WOL_ETC" "$WOL_ETC/secrets" "$WOL_ETC/prompts"
    chmod 750 "$WOL_ETC" "$WOL_ETC/prompts"
    chmod 700 "$WOL_ETC/secrets"
}

write_env_file() {
    local env_file="$WOL_ETC/wol-ai.env"
    [[ -f "$env_file" ]] && { info "Env file already exists; skipping"; return; }
    cat > "$env_file" <<EOF
SPIFFE_ENDPOINT_SOCKET=unix://$SPIRE_SOCKET
SPIFFE_TRUST_DOMAIN=spiffe://wol
AI_API_KEY_FILE=$WOL_ETC/secrets/api_key
PROMPT_TEMPLATE_DIR=$WOL_ETC/prompts
RATE_LIMIT_PER_CALLER_RPM=60
EOF
    chown "root:$WOL_USER" "$env_file"; chmod 640 "$env_file"
    info "Env file written to $env_file"
}

write_systemd_unit() {
    cat > /etc/systemd/system/wol-ai.service <<EOF
[Unit]
Description=WOL AI Service (prod)
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
    info "Systemd unit written."
}

configure_firewall() {
    fw_reset
    fw_allow_ssh
    iptables -A INPUT -s "$PROD_NET" -p tcp --dport "$API_PORT" -j ACCEPT
    iptables -A INPUT -s "$TEST_NET" -p tcp --dport "$API_PORT" -j ACCEPT
    fw_enable
}

main() {
    disable_ipv6
    configure_network
    install_packages
    setup_user
    setup_directories
    write_env_file
    write_systemd_unit
    configure_firewall
    info "wol-ai-prod host environment is ready."
}

main "$@"
