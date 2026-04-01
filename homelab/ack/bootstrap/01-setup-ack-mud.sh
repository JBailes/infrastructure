#!/usr/bin/env bash
# 01-setup-ack-mud.sh -- Set up an ACK! MUD server
#
# Runs on: any ACK! MUD LXC (acktng, ack431, ack42, ack41, assault30)
#
# Parameterized via environment variables:
#   MUD_NAME    -- hostname (e.g. acktng)
#   MUD_IP      -- internal IP (e.g. 10.1.0.241)
#   MUD_PORT    -- game port (default: 4000)
#   MUD_REPO    -- git repo URL for the MUD source (optional)
#
# Provides:
#   - Build dependencies (gcc, make, libcrypt-dev, zlib1g-dev, libssl-dev)
#   - IPv6 disabled
#   - DNS and default route via ACK! gateway (10.1.0.240)
#   - apt proxy via apt-cache (10.1.0.115:3142)
#   - Firewall: SSH from ACK! network, game port from ACK! network
#
# The MUD source code must be deployed separately after this script runs.

set -euo pipefail

MUD_NAME="${MUD_NAME:?Set MUD_NAME (e.g. acktng)}"
MUD_IP="${MUD_IP:?Set MUD_IP (e.g. 10.1.0.241)}"
MUD_PORT="${MUD_PORT:-4000}"
GW_IP="10.1.0.240"
ACK_NET="10.1.0.0/24"
APT_CACHE_IP="10.1.0.115"
APT_CACHE_PORT="3142"

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
# Network: DNS and default route
# ---------------------------------------------------------------------------

configure_network() {
    info "Configuring DNS and default route via ACK! gateway"

    cat > /etc/resolv.conf <<EOF
nameserver $GW_IP
EOF

    ip route del default 2>/dev/null || true
    ip route add default via "$GW_IP"
    info "Default route set via $GW_IP"
}

# ---------------------------------------------------------------------------
# apt proxy (apt-cacher-ng on apt-cache host)
# ---------------------------------------------------------------------------

configure_apt_proxy() {
    info "Configuring apt proxy ($APT_CACHE_IP:$APT_CACHE_PORT)"
    mkdir -p /etc/apt/apt.conf.d
    echo "Acquire::http::Proxy \"http://${APT_CACHE_IP}:${APT_CACHE_PORT}\";" \
        > /etc/apt/apt.conf.d/01proxy
}

# ---------------------------------------------------------------------------
# Packages (build tools for C MUD servers)
# ---------------------------------------------------------------------------

install_packages() {
    info "Installing build dependencies"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y --no-install-recommends \
        build-essential gcc make \
        libcrypt-dev zlib1g-dev libssl-dev libpq-dev \
        liblua5.4-dev \
        pkg-config git curl ca-certificates ufw
}

# ---------------------------------------------------------------------------
# Firewall
# ---------------------------------------------------------------------------

configure_firewall() {
    info "Configuring firewall"
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing

    # SSH from ACK! network
    ufw allow from "$ACK_NET" to any port 22 proto tcp

    # Game port from ACK! network (gateway forwards external traffic here)
    ufw allow from "$ACK_NET" to any port "$MUD_PORT" proto tcp

    ufw --force enable
    info "Firewall enabled (SSH + game port $MUD_PORT)"
}

# ---------------------------------------------------------------------------
# MUD directory structure
# ---------------------------------------------------------------------------

setup_directories() {
    info "Creating MUD directory structure"
    mkdir -p /opt/mud/src /opt/mud/area /opt/mud/player /opt/mud/log
    info "MUD directories created at /opt/mud/"
}

# ---------------------------------------------------------------------------
# Clone MUD source (if repo provided)
# ---------------------------------------------------------------------------

clone_source() {
    if [[ -n "${MUD_REPO:-}" ]]; then
        info "Cloning MUD source from $MUD_REPO"
        if [[ -d /opt/mud/src/.git ]]; then
            cd /opt/mud/src && git pull
        else
            git clone "$MUD_REPO" /opt/mud/src
        fi
    else
        info "No MUD_REPO set, skipping source clone"
        info "Deploy source manually to /opt/mud/src/"
    fi
}

# ---------------------------------------------------------------------------
# Build MUD source (if cloned)
# ---------------------------------------------------------------------------

build_source() {
    if [[ ! -d /opt/mud/src/.git ]]; then
        info "No source to build, skipping"
        return
    fi

    info "Building MUD source"
    cd /opt/mud/src

    # ACK! MUDs typically build from src/ subdirectory.
    # Use "make ack" if available (acktng), otherwise bare "make".
    # Avoid "make all" which may require clang-format or run tests.
    #
    # Some repos (e.g. ACKFUSS) nest the source one level deeper
    # (ackfuss-4.4.1/src/Makefile). The root Makefile delegates, so
    # building from the repo root handles both layouts.
    if [[ -f src/Makefile ]]; then
        cd src
        make clean 2>/dev/null || true
        if make -n ack &>/dev/null; then
            make ack
        else
            make
        fi
        info "Build complete (from src/)"
    elif [[ -f Makefile ]]; then
        make clean 2>/dev/null || true
        if make -n ack &>/dev/null; then
            make ack
        else
            make
        fi
        info "Build complete"
    else
        info "No Makefile found, skipping build"
    fi
}

# ---------------------------------------------------------------------------
# Systemd service unit
# ---------------------------------------------------------------------------

setup_systemd() {
    if [[ ! -d /opt/mud/src/.git ]]; then
        info "No source deployed, skipping systemd unit"
        return
    fi

    info "Creating systemd service unit for $MUD_NAME"

    if [[ "$MUD_NAME" == "acktng" ]]; then
        # acktng uses its own startup script which handles building,
        # TLS detection, and multi-port launch. Override ports via env vars:
        # PORT=4000 (game), TLS/WSS/WS disabled (no certs on ACK network).
        cat > /etc/systemd/system/mud.service <<UNIT
[Unit]
Description=ACK!TNG MUD server
After=network.target

[Service]
Type=exec
WorkingDirectory=/opt/mud/src
Environment=PORT=$MUD_PORT
Environment=TLS_PORT=0
Environment=WSS_PORT=0
Environment=WS_PORT=0
ExecStart=/opt/mud/src/startup
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT
    else
        # Legacy MUDs: binary is built as src/ack (if src/Makefile) or
        # ./ack (if root Makefile). Some repos (e.g. ACKFUSS) nest one
        # level deeper (ackfuss-4.4.1/src/ack). Search up to 3 levels.
        local binary=""
        binary=$(find /opt/mud/src -maxdepth 3 -name "ack" -type f -executable 2>/dev/null | head -1)
        if [[ -z "$binary" ]]; then
            info "WARNING: no ack binary found, skipping systemd unit"
            return
        fi

        local area_dir=""
        area_dir=$(find /opt/mud/src -maxdepth 2 -name "area" -type d 2>/dev/null | head -1)
        if [[ -z "$area_dir" ]]; then
            info "WARNING: no area/ directory found, skipping systemd unit"
            return
        fi

        cat > /etc/systemd/system/mud.service <<UNIT
[Unit]
Description=$MUD_NAME MUD server
After=network.target

[Service]
Type=exec
WorkingDirectory=$area_dir
ExecStart=$binary $MUD_PORT
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT
    fi

    systemctl daemon-reload
    systemctl enable mud.service
    info "Systemd unit created and enabled (mud.service)"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    info "Setting up ACK! MUD server: $MUD_NAME ($MUD_IP, port $MUD_PORT)"

    disable_ipv6
    configure_network
    configure_apt_proxy
    install_packages
    configure_firewall
    setup_directories
    clone_source
    build_source
    setup_systemd

    cat <<EOF

================================================================
$MUD_NAME host environment is ready ($MUD_IP).

Game port:    $MUD_PORT (forwarded from gateway)
Source dir:   /opt/mud/src/
Area dir:     /opt/mud/area/
Player dir:   /opt/mud/player/
Log dir:      /opt/mud/log/
Service:      mud.service (enabled, start with: systemctl start mud)

Next steps:
  1. Migrate any player data to /opt/mud/src/player/
  2. Start: systemctl start mud
================================================================
EOF
}

main "$@"
