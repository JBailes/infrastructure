#!/usr/bin/env bash
# 10-setup-wolf.sh -- Create a Docker LXC with Wolf cloud gaming and Wolf Den
#
# Runs on: the Proxmox host (creates an LXC via community script, then
#           configures it)
# Prereq: GPU drivers must be installed on the Proxmox host
#
# Usage:
#   ./10-setup-wolf.sh [OPTIONS]
#   ./10-setup-wolf.sh --configure   # (internal) Run inside the container
#
# Options:
#   --ctid <id>        Container ID (default: 120)
#   --cpu <cores>      CPU cores (default: 4)
#   --ram <mb>         RAM in MB (default: 4096)
#   --disk <gb>        Disk in GB (default: 16)
#   --storage <name>   Proxmox storage name (default: prompt user)
#
# Creates a privileged Debian LXC via lib/common.sh, installs Docker inside,
# then deploys:
#   - Wolf (ghcr.io/games-on-whales/wolf:stable) for Moonlight game streaming
#   - Wolf Den (ghcr.io/games-on-whales/wolf-den:stable) web management UI
#
# GPU passthrough is configured automatically based on the detected vendor.
# If multiple GPUs are found, the user is prompted to select one.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Defaults (overridable via flags)
CTID=120
CT_CPU=4
CT_RAM=4096
CT_DISK=16
CT_STORAGE="auto"

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
warn() { echo "WARN: $*" >&2; }

# =========================================================================
# GPU detection (runs on Proxmox host)
# =========================================================================

# Populate parallel arrays: GPU_RENDER_NODES, GPU_DRIVERS, GPU_VENDORS
detect_gpus() {
    GPU_RENDER_NODES=()
    GPU_DRIVERS=()
    GPU_VENDORS=()

    local node driver vendor
    for node in /sys/class/drm/renderD*/device/driver; do
        [[ -e "$node" ]] || continue
        local render_dev="/dev/dri/$(basename "$(dirname "$(dirname "$node")")")"
        driver=$(basename "$(readlink "$node")")

        case "$driver" in
            i915|xe)   vendor="Intel" ;;
            amdgpu)    vendor="AMD"   ;;
            nvidia)    vendor="NVIDIA" ;;
            *)         vendor="Unknown ($driver)" ;;
        esac

        GPU_RENDER_NODES+=("$render_dev")
        GPU_DRIVERS+=("$driver")
        GPU_VENDORS+=("$vendor")
    done

    if [[ ${#GPU_RENDER_NODES[@]} -eq 0 ]]; then
        err "No GPU render devices found in /sys/class/drm/. Are GPU drivers installed on the host?"
    fi
}

# Prompt the user to select a GPU. Sets SELECTED_RENDER_NODE, SELECTED_DRIVER,
# SELECTED_VENDOR.
select_gpu() {
    detect_gpus

    if [[ ${#GPU_RENDER_NODES[@]} -eq 1 ]]; then
        SELECTED_RENDER_NODE="${GPU_RENDER_NODES[0]}"
        SELECTED_DRIVER="${GPU_DRIVERS[0]}"
        SELECTED_VENDOR="${GPU_VENDORS[0]}"
        info "Detected GPU: ${SELECTED_RENDER_NODE} (${SELECTED_DRIVER}, ${SELECTED_VENDOR})"
        return
    fi

    echo ""
    echo "Available GPUs:"
    local i
    for i in "${!GPU_RENDER_NODES[@]}"; do
        printf "  %d) %s (%s, %s)\n" $((i + 1)) "${GPU_RENDER_NODES[$i]}" "${GPU_DRIVERS[$i]}" "${GPU_VENDORS[$i]}"
    done
    echo ""

    local choice
    while true; do
        read -rp "Select GPU for Wolf [1]: " choice
        choice="${choice:-1}"
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#GPU_RENDER_NODES[@]} )); then
            break
        fi
        echo "Invalid selection. Enter a number between 1 and ${#GPU_RENDER_NODES[@]}."
    done

    local idx=$((choice - 1))
    SELECTED_RENDER_NODE="${GPU_RENDER_NODES[$idx]}"
    SELECTED_DRIVER="${GPU_DRIVERS[$idx]}"
    SELECTED_VENDOR="${GPU_VENDORS[$idx]}"
    info "Selected GPU: ${SELECTED_RENDER_NODE} (${SELECTED_DRIVER}, ${SELECTED_VENDOR})"
}

# =========================================================================
# Storage detection (runs on Proxmox host)
# =========================================================================

# Query Proxmox for available storage that supports rootdir (CT root disks)
# and prompt the user to select one. Sets CT_STORAGE.
select_storage() {
    local storages=()
    local storage_info=()

    while IFS='|' read -r name type content enabled; do
        # Only include enabled storage that supports rootdir
        [[ "$enabled" == "1" ]] || continue
        [[ "$content" == *"rootdir"* ]] || continue
        storages+=("$name")
        storage_info+=("${name} (${type})")
    done < <(pvesm status --content rootdir 2>/dev/null \
        | awk 'NR>1 {printf "%s|%s|rootdir|%s\n", $1, $2, ($3=="active"?"1":"0")}')

    if [[ ${#storages[@]} -eq 0 ]]; then
        err "No active Proxmox storage with rootdir content found"
    fi

    if [[ ${#storages[@]} -eq 1 ]]; then
        CT_STORAGE="${storages[0]}"
        info "Using storage: ${storage_info[0]}"
        return
    fi

    echo ""
    echo "Available storage:"
    local i
    for i in "${!storages[@]}"; do
        printf "  %d) %s\n" $((i + 1)) "${storage_info[$i]}"
    done
    echo ""

    local choice
    while true; do
        read -rp "Select storage for Wolf CT [1]: " choice
        choice="${choice:-1}"
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#storages[@]} )); then
            break
        fi
        echo "Invalid selection. Enter a number between 1 and ${#storages[@]}."
    done

    CT_STORAGE="${storages[$((choice - 1))]}"
    info "Selected storage: ${CT_STORAGE}"
}

# =========================================================================
# LXC GPU passthrough configuration (runs on Proxmox host)
# =========================================================================

configure_gpu_passthrough() {
    local ctid="$1"
    local conf="/etc/pve/lxc/${ctid}.conf"

    info "Configuring GPU passthrough for ${SELECTED_VENDOR} (${SELECTED_DRIVER})"

    # Common: /dev/dri for all GPU types
    cat >> "$conf" <<'EOF'

# GPU passthrough (Wolf cloud gaming)
lxc.cgroup2.devices.allow: c 226:* rwm
lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir
EOF

    # Input devices for virtual gamepads
    cat >> "$conf" <<'EOF'
lxc.cgroup2.devices.allow: c 13:* rwm
lxc.cgroup2.devices.allow: c 10:223 rwm
lxc.mount.entry: /dev/uinput dev/uinput none bind,optional,create=file
lxc.mount.entry: /dev/uhid dev/uhid none bind,optional,create=file
lxc.mount.entry: /dev/input dev/input none bind,optional,create=dir
lxc.mount.entry: /run/udev run/udev none bind,optional,create=dir
EOF

    case "$SELECTED_VENDOR" in
        NVIDIA)
            cat >> "$conf" <<'EOF'
lxc.cgroup2.devices.allow: c 195:* rwm
lxc.cgroup2.devices.allow: c 507:* rwm
lxc.mount.entry: /dev/nvidia0 dev/nvidia0 none bind,optional,create=file
lxc.mount.entry: /dev/nvidiactl dev/nvidiactl none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-modeset dev/nvidia-modeset none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-uvm dev/nvidia-uvm none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-uvm-tools dev/nvidia-uvm-tools none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-caps dev/nvidia-caps none bind,optional,create=dir
EOF
            ;;
        AMD)
            # AMD also needs /dev/kfd for compute
            if [[ -e /dev/kfd ]]; then
                cat >> "$conf" <<'EOF'
lxc.cgroup2.devices.allow: c 234:* rwm
lxc.mount.entry: /dev/kfd dev/kfd none bind,optional,create=file
EOF
            fi
            ;;
        Intel)
            # Intel only needs /dev/dri (already configured above)
            ;;
    esac
}

# =========================================================================
# Container-side configuration (runs inside the LXC)
# =========================================================================

configure() {
    err()  { echo "ERROR: $*" >&2; exit 1; }
    info() { echo "==> $*"; }

    # These are passed via environment from the host side
    local gpu_vendor="${WOLF_GPU_VENDOR:?WOLF_GPU_VENDOR not set}"
    local gpu_driver="${WOLF_GPU_DRIVER:?WOLF_GPU_DRIVER not set}"
    local render_node="${WOLF_RENDER_NODE:-/dev/dri/renderD128}"

    info "Configuring Wolf for ${gpu_vendor} GPU (${gpu_driver}, ${render_node})"

    # -------------------------------------------------------------------
    # Install Docker
    # -------------------------------------------------------------------
    if ! command -v docker &>/dev/null; then
        info "Installing Docker"
        apt-get update -qq
        apt-get install -y --no-install-recommends ca-certificates curl gnupg

        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/debian/gpg \
            | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg

        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
            > /etc/apt/sources.list.d/docker.list

        apt-get update -qq
        apt-get install -y --no-install-recommends \
            docker-ce docker-ce-cli containerd.io docker-compose-plugin
        info "Docker installed"
    else
        info "Docker already installed"
    fi

    # -------------------------------------------------------------------
    # udev rules for virtual input devices
    # -------------------------------------------------------------------
    info "Setting up udev rules for virtual input"
    cat > /etc/udev/rules.d/85-wolf-virtual-inputs.rules <<'UDEV'
KERNEL=="uinput", SUBSYSTEM=="misc", MODE="0660", GROUP="input"
KERNEL=="uhid", GROUP="input", MODE="0660"
KERNEL=="hidraw*", ATTRS{name}=="Wolf PS5 (virtual) pad", GROUP="input"
SUBSYSTEMS=="input", ATTRS{name}=="Wolf X-Box One (virtual) pad", MODE="0660"
SUBSYSTEMS=="input", ATTRS{name}=="Wolf PS5 (virtual) pad", MODE="0660"
SUBSYSTEMS=="input", ATTRS{name}=="Wolf gamepad (virtual) motion sensors", MODE="0660"
SUBSYSTEMS=="input", ATTRS{name}=="Wolf Nintendo (virtual) pad", MODE="0660"
UDEV
    udevadm control --reload-rules 2>/dev/null || true
    udevadm trigger 2>/dev/null || true

    # -------------------------------------------------------------------
    # Create Wolf directories
    # -------------------------------------------------------------------
    mkdir -p /etc/wolf/cfg /etc/wolf/wolf-den /etc/wolf/covers /opt/wolf

    # -------------------------------------------------------------------
    # Write Wolf config with Steam app
    # -------------------------------------------------------------------
    if [[ ! -f /etc/wolf/cfg/config.toml ]]; then
        info "Writing Wolf config with Steam"
        cat > /etc/wolf/cfg/config.toml <<'TOML'
hostname = "Wolf"
support_hevc = true
support_av1 = true

[[profiles]]
uid = "default"

[[profiles.apps]]
title = "Steam"
start_virtual_compositor = true

[profiles.apps.runner]
type = "docker"
name = "WolfSteam"
image = "ghcr.io/games-on-whales/steam:edge"
mounts = ["/etc/wolf/steam:/home/retro:rw"]
env = ["PROTON_LOG=1", "RUN_SWAY=true"]
TOML
        mkdir -p /etc/wolf/steam
    else
        info "Wolf config already exists, skipping"
    fi

    # -------------------------------------------------------------------
    # Write docker-compose.yml
    # -------------------------------------------------------------------
    info "Writing docker-compose.yml for ${gpu_vendor}"

    case "$gpu_vendor" in
        NVIDIA)
            write_compose_nvidia "$render_node"
            ;;
        AMD|Intel)
            write_compose_amd_intel "$render_node"
            ;;
        *)
            err "Unsupported GPU vendor: $gpu_vendor"
            ;;
    esac

    # -------------------------------------------------------------------
    # NVIDIA driver volume (manual method, recommended by Wolf docs)
    # -------------------------------------------------------------------
    if [[ "$gpu_vendor" == "NVIDIA" ]]; then
        setup_nvidia_driver_volume
    fi

    # -------------------------------------------------------------------
    # Pull and start
    # -------------------------------------------------------------------
    info "Pulling and starting Wolf + Wolf Den"
    cd /opt/wolf
    docker compose pull
    docker compose up -d

    info "Waiting for services to start..."
    sleep 5

    if docker compose ps --format '{{.Service}} {{.State}}' | grep -q "running"; then
        info "Services are running"
    else
        warn "Some services may not be running yet. Check: docker compose -f /opt/wolf/docker-compose.yml ps"
    fi

    # -------------------------------------------------------------------
    # Summary
    # -------------------------------------------------------------------
    local ip
    ip=$(hostname -I 2>/dev/null | awk '{print $1}') || ip="<CONTAINER_IP>"

    cat <<EOF

================================================================
Wolf cloud gaming is deployed.

  Wolf:      streaming on ports 47984-48200 (Moonlight)
  Wolf Den:  http://${ip}:8080 (web management)
  GPU:       ${gpu_vendor} (${gpu_driver}) at ${render_node}

To pair with Moonlight:
  1. Open Moonlight, add server: ${ip}
  2. Check Wolf logs for PIN: docker logs wolf-wolf-1
  3. Enter PIN at: http://${ip}:47989/pin/#<PIN>
================================================================
EOF
}

# -------------------------------------------------------------------
# Compose file generators
# -------------------------------------------------------------------

write_compose_amd_intel() {
    local render_node="$1"
    cat > /opt/wolf/docker-compose.yml <<YAML
services:
  wolf:
    image: ghcr.io/games-on-whales/wolf:stable
    environment:
      - WOLF_RENDER_NODE=${render_node}
      - XDG_RUNTIME_DIR=/tmp/sockets
      - WOLF_CFG_FILE=/etc/wolf/cfg/config.toml
      - WOLF_DOCKER_SOCKET=/var/run/docker.sock
    volumes:
      - /etc/wolf:/etc/wolf
      - /var/run/docker.sock:/var/run/docker.sock:rw
      - /dev/:/dev/:rw
      - /run/udev:/run/udev:rw
      - wolf-socket:/tmp/sockets
    device_cgroup_rules:
      - 'c 13:* rmw'
    devices:
      - /dev/dri
      - /dev/uinput
      - /dev/uhid
    network_mode: host
    restart: unless-stopped

  wolf-den:
    image: ghcr.io/games-on-whales/wolf-den:stable
    environment:
      - WOLF_SOCKET_PATH=/tmp/sockets/wolf.sock
    volumes:
      - wolf-socket:/tmp/sockets
      - /etc/wolf/wolf-den:/app/wolf-den
      - /etc/wolf/covers:/etc/wolf/covers
    ports:
      - "8080:8080"
    restart: unless-stopped
    depends_on:
      - wolf

volumes:
  wolf-socket:
YAML
}

write_compose_nvidia() {
    local render_node="$1"
    cat > /opt/wolf/docker-compose.yml <<YAML
services:
  wolf:
    image: ghcr.io/games-on-whales/wolf:stable
    environment:
      - WOLF_RENDER_NODE=${render_node}
      - NVIDIA_DRIVER_VOLUME_NAME=nvidia-driver-vol
      - XDG_RUNTIME_DIR=/tmp/sockets
      - WOLF_CFG_FILE=/etc/wolf/cfg/config.toml
      - WOLF_DOCKER_SOCKET=/var/run/docker.sock
    volumes:
      - /etc/wolf:/etc/wolf:rw
      - /var/run/docker.sock:/var/run/docker.sock:rw
      - /dev/:/dev/:rw
      - /run/udev:/run/udev:rw
      - nvidia-driver-vol:/usr/nvidia:rw
      - wolf-socket:/tmp/sockets
    devices:
      - /dev/dri
      - /dev/uinput
      - /dev/uhid
      - /dev/nvidia-uvm
      - /dev/nvidia-uvm-tools
      - /dev/nvidia-caps/nvidia-cap1
      - /dev/nvidia-caps/nvidia-cap2
      - /dev/nvidiactl
      - /dev/nvidia0
      - /dev/nvidia-modeset
    device_cgroup_rules:
      - 'c 13:* rmw'
    network_mode: host
    restart: unless-stopped

  wolf-den:
    image: ghcr.io/games-on-whales/wolf-den:stable
    environment:
      - WOLF_SOCKET_PATH=/tmp/sockets/wolf.sock
    volumes:
      - wolf-socket:/tmp/sockets
      - /etc/wolf/wolf-den:/app/wolf-den
      - /etc/wolf/covers:/etc/wolf/covers
    ports:
      - "8080:8080"
    restart: unless-stopped
    depends_on:
      - wolf

volumes:
  nvidia-driver-vol:
    external: true
  wolf-socket:
YAML
}

setup_nvidia_driver_volume() {
    local nv_version="${WOLF_NV_VERSION:?WOLF_NV_VERSION not set}"
    info "Setting up NVIDIA driver volume (driver version: ${nv_version})"

    if docker volume inspect nvidia-driver-vol &>/dev/null; then
        info "NVIDIA driver volume already exists"
        return
    fi

    info "Building NVIDIA driver volume (this may take a few minutes)..."
    curl -fsSL https://raw.githubusercontent.com/games-on-whales/gow/master/images/nvidia-driver/Dockerfile \
        | docker build -t gow/nvidia-driver:latest -f - --build-arg NV_VERSION="${nv_version}" .

    docker create --rm --mount source=nvidia-driver-vol,destination=/usr/nvidia gow/nvidia-driver:latest sh
    info "NVIDIA driver volume created"
}

# =========================================================================
# Host-side: create CT and deploy (runs on the Proxmox host)
# =========================================================================

host_main() {
    [[ $EUID -eq 0 ]] || err "Run as root"

    # -----------------------------------------------------------------
    # Parse arguments
    # -----------------------------------------------------------------
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ctid)     CTID="${2:?--ctid requires a value}"; shift 2 ;;
            --cpu)      CT_CPU="${2:?--cpu requires a value}"; shift 2 ;;
            --ram)      CT_RAM="${2:?--ram requires a value}"; shift 2 ;;
            --disk)     CT_DISK="${2:?--disk requires a value}"; shift 2 ;;
            --storage)  CT_STORAGE="${2:?--storage requires a value}"; shift 2 ;;
            *)          err "Unknown option: $1" ;;
        esac
    done

    info "Wolf Cloud Gaming Setup"
    echo "  CTID:    ${CTID}"
    echo "  CPU:     ${CT_CPU} cores"
    echo "  RAM:     ${CT_RAM} MB"
    echo "  Disk:    ${CT_DISK} GB"
    echo "  Storage: ${CT_STORAGE}"
    echo ""

    # -----------------------------------------------------------------
    # GPU selection
    # -----------------------------------------------------------------
    select_gpu

    # -----------------------------------------------------------------
    # Storage selection (if not specified via --storage)
    # -----------------------------------------------------------------
    if [[ "$CT_STORAGE" == "auto" ]]; then
        select_storage
    fi

    # -----------------------------------------------------------------
    # Create LXC container
    # -----------------------------------------------------------------
    source "$SCRIPT_DIR/lib/common.sh"
    STORAGE="$CT_STORAGE"

    local ip="192.168.1.${CTID}"
    if create_lxc "$CTID" "wolf" "$ip" "$CT_RAM" "$CT_CPU" "$CT_DISK" "$ROUTER_GW" "yes"; then
        pct start "$CTID"
        sleep 3
    fi

    # -----------------------------------------------------------------
    # Configure GPU passthrough in LXC config
    # -----------------------------------------------------------------
    # Stop the container to modify its config safely
    pct stop "$CTID" 2>/dev/null || true
    sleep 2

    # Remove any previous Wolf GPU config to be idempotent
    local conf="/etc/pve/lxc/${CTID}.conf"
    if grep -q "# GPU passthrough (Wolf cloud gaming)" "$conf" 2>/dev/null; then
        info "Removing old GPU passthrough config"
        sed -i '/# GPU passthrough (Wolf cloud gaming)/,$ d' "$conf"
    fi

    configure_gpu_passthrough "$CTID"

    # -----------------------------------------------------------------
    # Start container and deploy
    # -----------------------------------------------------------------
    pct start "$CTID"
    sleep 3

    # Detect NVIDIA driver version on the host (where nvidia-smi is available)
    local nv_version=""
    if [[ "$SELECTED_VENDOR" == "NVIDIA" ]]; then
        if [[ -f /proc/driver/nvidia/version ]]; then
            nv_version=$(awk '/NVRM version/{print $8}' /proc/driver/nvidia/version)
        elif command -v nvidia-smi &>/dev/null; then
            nv_version=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)
        else
            err "Cannot determine NVIDIA driver version. Is the NVIDIA driver installed on this host?"
        fi
        info "Host NVIDIA driver version: ${nv_version}"
    fi

    info "Deploying Wolf configuration into CT ${CTID}"
    pct push "$CTID" "$0" /root/10-setup-wolf.sh --perms 0755
    pct exec "$CTID" -- bash -c \
        "WOLF_GPU_VENDOR='${SELECTED_VENDOR}' \
         WOLF_GPU_DRIVER='${SELECTED_DRIVER}' \
         WOLF_RENDER_NODE='${SELECTED_RENDER_NODE}' \
         WOLF_NV_VERSION='${nv_version}' \
         DEBIAN_FRONTEND=noninteractive \
         /root/10-setup-wolf.sh --configure"

    info "Done"
}

# =========================================================================
# Main
# =========================================================================

if [[ "${1:-}" == "--configure" ]]; then
    configure
else
    host_main "$@"
fi
