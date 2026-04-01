#!/usr/bin/env bash
# lib/common.sh -- Shared functions for WOL bootstrap scripts
#
# Source this from any bootstrap script using source_lib (see below),
# or directly if the path is known:
#   source /root/lib/common.sh    # inside a deployed container
#
# Provides:
#   - Logging helpers (err, info, warn)
#   - Boot-time secret scrub
#   - Network setup (IPv6 disable, ECMP routing, DNS, NTP)
#   - Service user creation
#   - .NET 9 runtime/SDK installation (via caching proxy on nginx-proxy)
#   - Certificate enrollment via cfssl CA
#   - iptables firewall boilerplate

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
warn() { echo "WARN: $*" >&2; }

# ---------------------------------------------------------------------------
# Boot-time secret scrub
# ---------------------------------------------------------------------------

scrub_bootstrap_secrets() {
    rm -f /root/.env.bootstrap
}

# ---------------------------------------------------------------------------
# Network: disable IPv6
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
# Network: ECMP default route via both gateways
# ---------------------------------------------------------------------------

GW_A_PROD="10.0.0.200"
GW_B_PROD="10.0.0.201"
GW_A_TEST="10.0.1.200"
GW_B_TEST="10.0.1.201"

# Detect gateway IPs based on the host's primary IP.
# Test hosts (10.0.1.x) use test gateways, all others use prod gateways.
_detect_gateways() {
    local primary_ip
    primary_ip=$(hostname -I 2>/dev/null | awk '{print $1}') || true
    if [[ "$primary_ip" == 10.0.1.* ]]; then
        GW_A="$GW_A_TEST"
        GW_B="$GW_B_TEST"
    else
        GW_A="$GW_A_PROD"
        GW_B="$GW_B_PROD"
    fi
}
_detect_gateways

configure_ecmp_route() {
    info "Configuring ECMP default route via $GW_A and $GW_B"

    # Hash on L3+L4 (src/dst IP + port) so each TCP connection sticks to
    # one gateway. Without this, NAT state on gateway A is invisible to
    # gateway B, causing connection resets on long downloads.
    sysctl -w net.ipv4.fib_multipath_hash_policy=1 >/dev/null
    cat > /etc/sysctl.d/99-ecmp-hash.conf <<EOF
net.ipv4.fib_multipath_hash_policy = 1
EOF

    ip route del default 2>/dev/null || true
    ip route add default nexthop via "$GW_A" nexthop via "$GW_B"
}

# ---------------------------------------------------------------------------
# Network: DNS resolvers (both gateways)
# ---------------------------------------------------------------------------

configure_dns() {
    cat > /etc/resolv.conf <<EOF
nameserver $GW_A
nameserver $GW_B
EOF
    info "DNS resolvers set to $GW_A and $GW_B"
}

# ---------------------------------------------------------------------------
# Network: NTP via both gateways (chrony)
# ---------------------------------------------------------------------------

configure_ntp() {
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

# Convenience: configure all three (DNS + NTP + ECMP route)
configure_network() {
    configure_ecmp_route
    configure_dns
    configure_ntp
}

# ---------------------------------------------------------------------------
# Service user creation
#
# Usage: create_service_user <username> <uid> <gid> <home_dir>
# ---------------------------------------------------------------------------

create_service_user() {
    local user="$1" uid="$2" gid="$3" home="$4"
    info "Creating $user user (UID $uid)"
    getent group "$gid" &>/dev/null || groupadd --gid "$gid" "$user"
    id -u "$user" &>/dev/null || useradd \
        --uid "$uid" \
        --gid "$gid" \
        --no-create-home \
        --home-dir "$home" \
        --shell /usr/sbin/nologin \
        "$user"
}

# ---------------------------------------------------------------------------
# .NET caching proxy
#
# nginx-proxy (CT 118) runs a caching reverse proxy on port 8080 that fronts
# dotnetcli.azureedge.net. All .NET downloads go through the cache so only the
# first VM hits Microsoft's CDN. The install functions below use this
# automatically via --azure-feed.
#
# The Microsoft APT repository is no longer used. Its GPG key uses SHA-1
# binding signatures, which sqv (the default apt verifier on Debian 13)
# rejects as of 2026-02-01.
# ---------------------------------------------------------------------------

DOTNET_CACHE_URL="http://10.0.0.118:8080"
DOTNET_CACHE_DIRECT="https://dotnetcli.azureedge.net"

# ---------------------------------------------------------------------------
# Grafana APT repository (for Promtail, Loki)
# ---------------------------------------------------------------------------

configure_grafana_repo() {
    if [[ -f /etc/apt/sources.list.d/grafana.list ]]; then
        return
    fi
    info "Adding Grafana package repository"
    # curl and gpg are needed to fetch and dearmor the signing key
    local need_update=0
    command -v curl &>/dev/null || need_update=1
    command -v gpg  &>/dev/null || need_update=1
    if [[ $need_update -eq 1 ]]; then
        apt-get update -qq
        apt-get install -y --no-install-recommends curl gnupg
    fi
    curl -fsSL https://apt.grafana.com/gpg.key \
        | gpg --dearmor -o /usr/share/keyrings/grafana.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
        > /etc/apt/sources.list.d/grafana.list
    apt-get update -qq
}

# ---------------------------------------------------------------------------
# .NET 9 runtime installation (via dotnet-install.sh + caching proxy)
# ---------------------------------------------------------------------------

DOTNET_ROOT="/usr/local/dotnet"

# _run_dotnet_install -- wrapper around dotnet-install.sh that tries the
# local caching proxy first, then falls back to the direct Microsoft CDN.
_run_dotnet_install() {
    local script="/tmp/dotnet-install.sh"
    if [[ ! -f "$script" ]]; then
        curl -fsSL https://dot.net/v1/dotnet-install.sh -o "$script"
        chmod +x "$script"
    fi

    # Try cache first, fall back to direct
    if bash "$script" --install-dir "$DOTNET_ROOT" --azure-feed "$DOTNET_CACHE_URL" "$@" 2>/dev/null; then
        return 0
    fi
    warn "Cache unreachable, downloading .NET directly from Microsoft"
    bash "$script" --install-dir "$DOTNET_ROOT" --azure-feed "$DOTNET_CACHE_DIRECT" "$@"
}

# Ensure dotnet is on PATH after install
_link_dotnet() {
    ln -sf "$DOTNET_ROOT/dotnet" /usr/local/bin/dotnet
    # pct exec uses a minimal PATH (/sbin:/bin:/usr/sbin:/usr/bin) that
    # excludes /usr/local/bin. Add a second symlink so dotnet is found
    # in bootstrap scripts run via pct exec.
    ln -sf "$DOTNET_ROOT/dotnet" /usr/bin/dotnet
}

install_dotnet_runtime() {
    local channel="${1:-9.0}"
    local runtime="${2:-aspnetcore}"

    if command -v dotnet &>/dev/null && dotnet --list-runtimes 2>/dev/null | grep -q "NETCore.App ${channel%%.*}"; then
        info ".NET ${channel} runtime already installed"
        return
    fi

    info "Installing .NET $channel runtime ($runtime) via dotnet-install.sh"
    _run_dotnet_install --channel "$channel" --runtime "$runtime"
    _link_dotnet
    info ".NET $channel runtime installed"
}

# ---------------------------------------------------------------------------
# .NET SDK installation (via dotnet-install.sh + caching proxy)
# ---------------------------------------------------------------------------

install_dotnet_sdk() {
    local channel="${1:-9.0}"

    if dotnet --list-sdks 2>/dev/null | grep -q "^${channel%%.*}\."; then
        info ".NET $channel SDK already installed"
        return
    fi

    info "Installing .NET $channel SDK via dotnet-install.sh"
    _run_dotnet_install --channel "$channel"
    _link_dotnet
    info ".NET $channel SDK installed"
}

# ---------------------------------------------------------------------------
# Certificate enrollment via cfssl CA
# Copy root CA cert from the WOL CA store to a service cert directory.
# pve-root-ca.sh distributes root_ca.crt to /etc/ssl/wol/ on all hosts.
#
# Usage: copy_root_ca <dest_dir>
#   dest_dir: directory to copy root_ca.crt into (created if missing)
# ---------------------------------------------------------------------------

copy_root_ca() {
    local dest_dir="$1"
    local src="/etc/ssl/wol/root_ca.crt"
    [[ -f "$src" ]] || { warn "Root CA not found at $src"; return 1; }
    mkdir -p "$dest_dir"
    cp "$src" "$dest_dir/root_ca.crt"
    chmod 644 "$dest_dir/root_ca.crt"
}

# ---------------------------------------------------------------------------
# Certificate enrollment via cfssl REST API
#
# Generates a key + CSR, sends to cfssl REST API, writes signed cert.
# The cfssl CA runs on 10.0.0.203:8443.
#
# Usage: enroll_cert_from_ca <cn> <cert_path> <key_path> <profile> [<san>...]
#   cn:        Common Name for the certificate
#   cert_path: where to write the signed certificate
#   key_path:  where to write the private key
#   profile:   cfssl signing profile (db-client, server)
#   san:       optional Subject Alternative Names (DNS or IP)
# ---------------------------------------------------------------------------

# CA is dual-homed: 10.0.0.203 (prod) and 10.0.1.203 (test).
if [[ "$(hostname -I 2>/dev/null | awk '{print $1}')" == 10.0.1.* ]]; then
    CA_HOST="10.0.1.203"
else
    CA_HOST="10.0.0.203"
fi
CA_PORT="8443"

enroll_cert_from_ca() {
    local cn="$1" cert_path="$2" key_path="$3" profile="$4"
    shift 4
    local sans=("$@")

    info "Enrolling certificate (CN=$cn, profile=$profile) from cfssl CA"

    # Generate EC P-256 key
    openssl ecparam -genkey -name prime256v1 -noout 2>/dev/null \
        | openssl pkcs8 -topk8 -nocrypt -out "$key_path"
    chmod 600 "$key_path"

    # Generate CSR with openssl
    local csr_file
    csr_file=$(mktemp)
    local san_csv=""
    if [[ ${#sans[@]} -gt 0 ]]; then
        for san in "${sans[@]}"; do
            if [[ "$san" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                san_csv="${san_csv:+$san_csv,}IP:$san"
            else
                san_csv="${san_csv:+$san_csv,}DNS:$san"
            fi
        done
        openssl req -new -key "$key_path" -out "$csr_file" \
            -subj "/CN=$cn/O=WOL Infrastructure" \
            -addext "subjectAltName=$san_csv"
    else
        openssl req -new -key "$key_path" -out "$csr_file" \
            -subj "/CN=$cn/O=WOL Infrastructure"
    fi

    # Sign via cfssl REST API
    local csr_pem
    csr_pem=$(cat "$csr_file")
    local response
    response=$(curl -sf -X POST "http://${CA_HOST}:${CA_PORT}/api/v1/cfssl/sign" \
        -H "Content-Type: application/json" \
        -d "{\"certificate_request\": $(echo "$csr_pem" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))'), \"profile\": \"$profile\"}" \
    ) || { err "cfssl sign request failed for CN=$cn"; return 1; }

    # Extract cert from JSON response
    echo "$response" | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"]["certificate"])' > "$cert_path"

    rm -f "$csr_file"
    chmod 644 "$cert_path"
    info "Certificate enrolled: $cert_path (CN=$cn)"
}

# ---------------------------------------------------------------------------
# iptables firewall boilerplate
#
# Usage:
#   fw_reset          # Flush rules, set default DROP incoming / ACCEPT outgoing
#   fw_allow_ssh      # Allow SSH from private network
#   iptables -A INPUT -s <src> -p tcp --dport <port> -j ACCEPT   # Add a rule
#   fw_enable         # Persist rules and enable restore on boot
#
# Between fw_reset and fw_enable, add service-specific rules:
#   iptables -A INPUT -s "$PROD_NET" -p tcp --dport 8443 -j ACCEPT
#   iptables -A INPUT -s "$TEST_NET" -p tcp --dport 8443 -j ACCEPT
#
# iptables is used directly for reliability in unprivileged LXC containers.
# ---------------------------------------------------------------------------

PROD_NET="10.0.0.0/24"
TEST_NET="10.0.1.0/24"

fw_reset() {
    info "Configuring firewall (iptables)"
    iptables -F INPUT 2>/dev/null || true
    iptables -F FORWARD 2>/dev/null || true
    iptables -P INPUT DROP
    iptables -P FORWARD DROP
    iptables -P OUTPUT ACCEPT
    iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    iptables -A INPUT -i lo -j ACCEPT
}

fw_allow_ssh() {
    iptables -A INPUT -s "$PROD_NET" -p tcp --dport 22 -j ACCEPT
    iptables -A INPUT -s "$TEST_NET" -p tcp --dport 22 -j ACCEPT
}

fw_enable() {
    # Persist rules so they survive reboot
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4

    # Restore on boot via a systemd oneshot (if not already installed)
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
    info "Firewall enabled (iptables)"
}

# Convenience: standard firewall (reset + SSH + enable, no extra rules)
configure_standard_firewall() {
    fw_reset
    fw_allow_ssh
    fw_enable
}

# ---------------------------------------------------------------------------
# Forward proxy configuration
#
# apt-cacher-ng caches .deb packages only. Other HTTP/HTTPS traffic
# (curl, wget, etc.) goes directly through the gateway NAT.
#
# The apt proxy config is pushed by the orchestrator (run_on_lxc/run_on_vm)
# before each bootstrap script, so calling this manually is only needed
# if a script runs outside the orchestrator.
# ---------------------------------------------------------------------------

APT_CACHE_HOST="10.0.0.115"
APT_CACHE_PORT="3142"

configure_apt_proxy() {
    info "Configuring apt proxy (http://${APT_CACHE_HOST}:${APT_CACHE_PORT})"
    mkdir -p /etc/apt/apt.conf.d
    echo "Acquire::http::Proxy \"http://${APT_CACHE_HOST}:${APT_CACHE_PORT}\";" \
        > /etc/apt/apt.conf.d/01proxy
}

# ---------------------------------------------------------------------------
# Proxy health check (systemd timer, runs every 1 minute)
#
# Installs a systemd timer that pings the apt-cache health endpoint.
# Logs warnings if the proxy is unreachable. Call after configure_proxy().
# ---------------------------------------------------------------------------

install_proxy_health_check() {
    info "Installing proxy health check timer"

    cat > /usr/local/bin/check-proxy-health <<'HEALTHCHECK'
#!/usr/bin/env bash
if curl -sf --max-time 5 http://10.0.0.115:8080/ >/dev/null 2>&1; then
    echo "$(date -Iseconds) proxy-health: ok"
else
    echo "$(date -Iseconds) proxy-health: UNREACHABLE" >&2
fi
HEALTHCHECK
    chmod 755 /usr/local/bin/check-proxy-health

    cat > /etc/systemd/system/proxy-health.service <<'SERVICE'
[Unit]
Description=Check apt-cache proxy health

[Service]
Type=oneshot
ExecStart=/usr/local/bin/check-proxy-health
SERVICE

    cat > /etc/systemd/system/proxy-health.timer <<'TIMER'
[Unit]
Description=Check apt-cache proxy health every minute

[Timer]
OnBootSec=30s
OnUnitActiveSec=1min
AccuracySec=10s

[Install]
WantedBy=timers.target
TIMER

    systemctl daemon-reload
    systemctl enable --now proxy-health.timer
    info "Proxy health check timer installed (every 1 minute)"
}

# ---------------------------------------------------------------------------
# PostgreSQL exporter for Prometheus
#
# Installs postgres_exporter on a database host. Creates a monitoring
# role in PostgreSQL (via peer auth), downloads the exporter binary,
# and sets up a systemd service on port 9187.
#
# Usage: install_postgres_exporter
# Prerequisites: PostgreSQL must be running, firewall must allow :9187
# ---------------------------------------------------------------------------

POSTGRES_EXPORTER_PORT="9187"

install_postgres_exporter() {
    info "Installing postgres_exporter"

    # Create monitoring role in PostgreSQL (peer auth, pg_monitor grants read-only stats access)
    if su -c "psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='monitoring'\"" postgres | grep -q 1; then
        info "PostgreSQL monitoring role already exists"
    else
        su -c "psql -c \"CREATE ROLE monitoring WITH LOGIN; GRANT pg_monitor TO monitoring;\"" postgres
        info "PostgreSQL monitoring role created"
    fi

    # Add peer auth for monitoring user (if not already present)
    local pg_hba
    pg_hba=$(find /etc/postgresql -name pg_hba.conf -print -quit 2>/dev/null)
    if [[ -n "$pg_hba" ]] && ! grep -q "monitoring.*peer" "$pg_hba"; then
        # Insert before the first 'reject' line
        sed -i "/^host.*all.*all.*reject/i local   all             monitoring                              peer" "$pg_hba"
        su -c "pg_ctlcluster $(pg_lsclusters -h | awk '{print $1, $2}') reload" postgres 2>/dev/null || true
        info "Added peer auth for monitoring user to pg_hba.conf"
    fi

    # Create system user matching the PostgreSQL role (for peer auth)
    if ! id -u monitoring &>/dev/null; then
        useradd --system --no-create-home --shell /usr/sbin/nologin monitoring
    fi

    # Install from Debian repos (prometheus-postgres-exporter)
    apt-get install -y --no-install-recommends prometheus-postgres-exporter

    # Systemd service (connects via peer auth using the monitoring system user).
    # Override the packaged service to use peer auth with our monitoring user.
    cat > /etc/systemd/system/postgres-exporter.service <<'SERVICE'
[Unit]
Description=Prometheus PostgreSQL Exporter
After=postgresql.service
Wants=postgresql.service

[Service]
Type=simple
User=monitoring
Environment=DATA_SOURCE_NAME=postgresql:///postgres?host=/var/run/postgresql
ExecStart=/usr/bin/prometheus-postgres-exporter --web.listen-address=:9187
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SERVICE

    systemctl daemon-reload
    systemctl enable --now postgres-exporter
    info "postgres_exporter running on :${POSTGRES_EXPORTER_PORT}"
}

# ---------------------------------------------------------------------------
# SPIRE Agent group membership
#
# Usage: add_to_spire_group <username>
# ---------------------------------------------------------------------------

add_to_spire_group() {
    local user="$1"
    local group="${2:-spire}"
    usermod -aG "$group" "$user"
    info "Added $user to $group group"
}
