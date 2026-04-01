#!/usr/bin/env bash
# 18-setup-wol-realm-test.sh -- Prepare wol-realm-test host environment
#
# Runs on: wol-realm-test (10.0.1.215) -- Debian 13 LXC (privileged)
# Run order: Step 13 (SPIRE Agent must already be running on this host)

set -euo pipefail
_LIB="$(dirname "$0")/../lib/common.sh"; [[ -f "$_LIB" ]] || _LIB="/root/lib/common.sh"; source "$_LIB"
scrub_bootstrap_secrets

REALM_NAME="wol-realm-test"
REALM_IP="10.0.1.215"
WOL_USER="wol-realm"
WOL_UID="1001"
WOL_GID="1001"
WOL_HOME="/var/lib/wol-realm"
WOL_LIB="/usr/lib/wol-realm"
WOL_ETC="/etc/wol-realm"
WOL_LOG="/var/log/wol-realm"
SPIRE_SOCKET="/var/run/spire/agent.sock"

[[ $EUID -eq 0 ]] || err "Run as root"

install_packages() {
    info "Installing packages"
    apt-get update -qq
    local icu_pkg
    icu_pkg=$(apt-cache search '^libicu[0-9]+$' | awk '{print $1}' | sort -V | tail -1)
    [[ -n "$icu_pkg" ]] || err "No libicu package found"
    apt-get install -y --no-install-recommends \
        curl ca-certificates iptables chrony build-essential gcc "$icu_pkg" libssl3
    install_dotnet_runtime "9.0" "aspnetcore"
}

setup_user() {
    create_service_user "$WOL_USER" "$WOL_UID" "$WOL_GID" "$WOL_HOME"
    add_to_spire_group "$WOL_USER"
}

setup_directories() {
    info "Creating directory structure"
    mkdir -p "$WOL_LIB/bin" "$WOL_LIB/app" "$WOL_HOME" "$WOL_ETC" "$WOL_LOG"
    chown -R "$WOL_USER:$WOL_USER" "$WOL_LIB" "$WOL_HOME" "$WOL_ETC" "$WOL_LOG"
    chmod 750 "$WOL_ETC"

    touch "$WOL_LOG/wol-realm.log"
    chown "$WOL_USER:$WOL_USER" "$WOL_LOG/wol-realm.log"
}

compile_wrapper() {
    info "Compiling workload wrapper binary"
    local src="/tmp/wol-realm-start.c" bin="$WOL_LIB/bin/start"
    cat > "$src" <<'C_SOURCE'
#include <unistd.h>
#include <stdio.h>
int main(void) {
    char *const argv[] = { "/usr/local/bin/dotnet", "/usr/lib/wol-realm/app/Wol.Realm.dll", NULL };
    execv(argv[0], argv);
    perror("execv failed");
    return 1;
}
C_SOURCE
    gcc -O2 -Wall -o "$bin" "$src"
    chown root:root "$bin"; chmod 755 "$bin"; rm -f "$src"
    info "Wrapper compiled: $bin"
}

write_env_file() {
    local env_file="$WOL_ETC/wol-realm.env"
    [[ -f "$env_file" ]] && { info "Env file already exists; skipping"; return; }
    cat > "$env_file" <<EOF
DOTNET_ROOT=$DOTNET_ROOT
SPIFFE_ENDPOINT_SOCKET=unix://$SPIRE_SOCKET
SPIFFE_TRUST_DOMAIN=spiffe://wol
EOF
    chown "root:$WOL_USER" "$env_file"; chmod 640 "$env_file"
    info "Env file written to $env_file"
}

write_systemd_unit() {
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
    systemctl enable wol-realm
    info "Systemd unit written. Service will start once binary is deployed."
}

main() {
    info "Setting up realm: $REALM_NAME ($REALM_IP)"
    disable_ipv6
    configure_network
    install_packages
    setup_user
    setup_directories
    compile_wrapper
    configure_standard_firewall
    write_env_file
    write_systemd_unit
    info "$REALM_NAME host environment is ready."
}

main "$@"
