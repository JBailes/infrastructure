#!/usr/bin/env bash
# 11-setup-ollama.sh -- Create an LXC with Ollama and AMD GPU passthrough
#
# Runs on: the Proxmox host (creates an LXC, then pushes and configures)
# Prereq: AMD GPU drivers (amdgpu) must be loaded on the Proxmox host
#
# Usage:
#   ./11-setup-ollama.sh [OPTIONS]
#   ./11-setup-ollama.sh --configure       # (internal) Run inside the container
#   ./11-setup-ollama.sh --deploy-only     # Re-deploy config to existing CT
#
# Options:
#   --ctid <id>        Container ID (default: 121)
#   --cpu <cores>      CPU cores (default: 8)
#   --ram <mb>         RAM in MB (default: 65536)
#   --disk <gb>        Disk in GB (default: 256)
#   --storage <name>   Proxmox storage name (default: large)
#   --model <tag>      Ollama model to pull after setup (default: qwen3.5:27b)
#   --no-model         Skip model pull

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Defaults
CTID=103
CT_CPU=8
CT_RAM=65536
CT_DISK=256
CT_STORAGE="large"
CT_MODEL="qwen3.5:27b"
DEPLOY_ONLY=false

# =========================================================================
# Container-side configuration (runs inside the LXC)
# =========================================================================

configure() {
    err()  { echo "ERROR: $*" >&2; exit 1; }
    info() { echo "==> $*"; }

    info "Configuring Ollama"

    # -------------------------------------------------------------------
    # Install Ollama
    # -------------------------------------------------------------------
    if ! command -v ollama &>/dev/null; then
        info "Installing Ollama"
        apt-get update -qq
        apt-get install -y --no-install-recommends curl ca-certificates zstd
        curl -fsSL https://ollama.com/install.sh | sh

        info "Installing ROCm libraries for AMD GPU support"
        curl -fsSL https://ollama.com/download/ollama-linux-amd64-rocm.tar.zst \
            | tar x --zstd -C /usr
        info "Ollama installed"
    else
        info "Ollama already installed"
    fi

    # -------------------------------------------------------------------
    # Configure Ollama systemd service
    # -------------------------------------------------------------------
    info "Configuring Ollama service"
    mkdir -p /etc/systemd/system/ollama.service.d
    cat > /etc/systemd/system/ollama.service.d/override.conf <<'EOF'
[Service]
Environment="OLLAMA_HOST=0.0.0.0:11434"
Environment="HSA_OVERRIDE_GFX_VERSION=11.0.0"
EOF

    systemctl daemon-reload
    systemctl enable ollama
    systemctl restart ollama

    # Wait for Ollama to be ready
    info "Waiting for Ollama to start..."
    local attempts=0
    while ! curl -sf http://localhost:11434/api/version &>/dev/null; do
        attempts=$((attempts + 1))
        if [[ $attempts -ge 30 ]]; then
            err "Ollama did not start within 30 seconds"
        fi
        sleep 1
    done

    # -------------------------------------------------------------------
    # Firewall: restrict Ollama to LAN only
    # -------------------------------------------------------------------
    info "Configuring firewall"
    apt-get install -y --no-install-recommends iptables

    # Flush any previous ollama rules to be idempotent
    iptables -D INPUT -p tcp --dport 11434 -s 127.0.0.1 -j ACCEPT 2>/dev/null || true
    iptables -D INPUT -p tcp --dport 11434 -s 192.168.0.0/23 -j ACCEPT 2>/dev/null || true
    iptables -D INPUT -p tcp --dport 11434 -j DROP 2>/dev/null || true

    iptables -A INPUT -p tcp --dport 11434 -s 127.0.0.1 -j ACCEPT
    iptables -A INPUT -p tcp --dport 11434 -s 192.168.0.0/23 -j ACCEPT
    iptables -A INPUT -p tcp --dport 11434 -j DROP

    # Persist rules across reboots
    mkdir -p /etc/iptables /etc/network/if-pre-up.d
    iptables-save > /etc/iptables/rules.v4
    cat > /etc/network/if-pre-up.d/iptables <<'IPTABLES'
#!/bin/sh
/sbin/iptables-restore < /etc/iptables/rules.v4
IPTABLES
    chmod +x /etc/network/if-pre-up.d/iptables

    # -------------------------------------------------------------------
    # Verify GPU access
    # -------------------------------------------------------------------
    if [[ -e /dev/kfd ]]; then
        info "AMD GPU compute device (/dev/kfd) is accessible"
    else
        echo "WARN: /dev/kfd not found -- GPU acceleration may not work" >&2
    fi

    if ls /dev/dri/renderD* &>/dev/null; then
        info "DRI render nodes available: $(ls /dev/dri/renderD*)"
    else
        echo "WARN: No DRI render nodes found" >&2
    fi

    # -------------------------------------------------------------------
    # Summary
    # -------------------------------------------------------------------
    local ip
    ip=$(hostname -I 2>/dev/null | awk '{print $1}') || ip="<CONTAINER_IP>"
    local version
    version=$(curl -sf http://localhost:11434/api/version | grep -o '"version":"[^"]*"' | cut -d'"' -f4) || version="unknown"

    cat <<EOF

================================================================
Ollama is deployed.

  API:       http://${ip}:11434
  Version:   ${version}
  GPU:       AMD 7900XTX (amdgpu) via /dev/kfd + /dev/dri

  Pull a model:  ollama pull qwen3:8b
  Test:          curl http://${ip}:11434/api/version
================================================================
EOF
}

# =========================================================================
# Host-side: create CT and deploy (runs on the Proxmox host)
# =========================================================================

host_main() {
    source "$SCRIPT_DIR/lib/common.sh"

    [[ $EUID -eq 0 ]] || err "Run as root"

    # -----------------------------------------------------------------
    # Parse arguments
    # -----------------------------------------------------------------
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ctid)         CTID="${2:?--ctid requires a value}"; shift 2 ;;
            --cpu)          CT_CPU="${2:?--cpu requires a value}"; shift 2 ;;
            --ram)          CT_RAM="${2:?--ram requires a value}"; shift 2 ;;
            --disk)         CT_DISK="${2:?--disk requires a value}"; shift 2 ;;
            --storage)      CT_STORAGE="${2:?--storage requires a value}"; shift 2 ;;
            --model)        CT_MODEL="${2:?--model requires a value}"; shift 2 ;;
            --no-model)     CT_MODEL=""; shift ;;
            --deploy-only)  DEPLOY_ONLY=true; shift ;;
            *)              err "Unknown option: $1" ;;
        esac
    done

    info "Ollama LXC Setup"
    echo "  CTID:    ${CTID}"
    echo "  CPU:     ${CT_CPU} cores"
    echo "  RAM:     ${CT_RAM} MB ($((CT_RAM / 1024)) GB)"
    echo "  Disk:    ${CT_DISK} GB"
    echo "  Storage: ${CT_STORAGE}"
    echo "  Model:   ${CT_MODEL:-none}"
    echo ""

    # -----------------------------------------------------------------
    # Verify AMD GPU is available
    # -----------------------------------------------------------------
    if [[ ! -e /dev/kfd ]]; then
        err "/dev/kfd not found. AMD GPU drivers (amdgpu) must be loaded on the host."
    fi

    local render_node=""
    for node in /sys/class/drm/renderD*/device/driver; do
        [[ -e "$node" ]] || continue
        local driver
        driver=$(basename "$(readlink "$node")")
        if [[ "$driver" == "amdgpu" ]]; then
            render_node="/dev/dri/$(basename "$(dirname "$(dirname "$node")")")"
            break
        fi
    done

    if [[ -z "$render_node" ]]; then
        err "No AMD GPU render device found. Is the amdgpu driver loaded?"
    fi
    info "Detected AMD GPU at ${render_node}"

    # -----------------------------------------------------------------
    # Create LXC container
    # -----------------------------------------------------------------
    local ip="192.168.1.${CTID}"
    STORAGE="$CT_STORAGE"

    if [[ "$DEPLOY_ONLY" == "true" ]]; then
        info "Deploy-only mode: skipping container creation"
    elif create_lxc "$CTID" "ollama" "$ip" "$CT_RAM" "$CT_CPU" "$CT_DISK" "$ROUTER_GW" "yes"; then
        # New container created -- configure GPU passthrough before first start
        configure_gpu_passthrough "$CTID"
        pct start "$CTID"
        sleep 3
    else
        # Container already exists
        info "Container already exists, re-deploying configuration"
    fi

    # Ensure container is running
    if ! pct status "$CTID" 2>/dev/null | grep -q running; then
        pct start "$CTID"
        sleep 3
    fi

    # -----------------------------------------------------------------
    # Deploy configuration
    # -----------------------------------------------------------------
    info "Deploying Ollama configuration into CT ${CTID}"
    pct push "$CTID" "$0" /root/11-setup-ollama.sh --perms 0755
    pct exec "$CTID" -- bash -c \
        "DEBIAN_FRONTEND=noninteractive /root/11-setup-ollama.sh --configure"

    # -----------------------------------------------------------------
    # Pull default model
    # -----------------------------------------------------------------
    if [[ -n "$CT_MODEL" ]]; then
        info "Pulling model: ${CT_MODEL} (this may take a while)"
        pct exec "$CTID" -- ollama pull "$CT_MODEL"
        info "Model ${CT_MODEL} ready"
    fi

    info "Done"
}

# =========================================================================
# GPU passthrough configuration (runs on Proxmox host)
# =========================================================================

configure_gpu_passthrough() {
    local ctid="$1"
    local conf="/etc/pve/lxc/${ctid}.conf"

    info "Configuring AMD GPU passthrough for CT ${ctid}"

    # Remove any previous GPU config to be idempotent
    if grep -q "# GPU passthrough (Ollama)" "$conf" 2>/dev/null; then
        info "Removing old GPU passthrough config"
        sed -i '/# GPU passthrough (Ollama)/,$ d' "$conf"
    fi

    cat >> "$conf" <<'EOF'

# GPU passthrough (Ollama)
lxc.cgroup2.devices.allow: c 226:* rwm
lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir
lxc.cgroup2.devices.allow: c 511:* rwm
lxc.mount.entry: /dev/kfd dev/kfd none bind,optional,create=file
EOF
}

# =========================================================================
# Main
# =========================================================================

if [[ "${1:-}" == "--configure" ]]; then
    configure
else
    host_main "$@"
fi
