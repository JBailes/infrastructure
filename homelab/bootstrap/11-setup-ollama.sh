#!/usr/bin/env bash
# 11-setup-llm.sh -- Create an LXC with llama.cpp (Vulkan) and AMD GPU passthrough
#
# Migrated from Ollama to llama.cpp with Vulkan backend for ~47% higher decode
# throughput on AMD GPUs (41 tok/s vs 28 tok/s on 7900XTX with 27B Q4_K_M).
# Default model: Qwen3.5-27B Claude Opus v2 distilled (Jackrong), Q4_K_M.
# See homelab/llm-benchmarks.md for full benchmark results.
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
#   --ctid <id>        Container ID (default: 103)
#   --cpu <cores>      CPU cores (default: 8)
#   --ram <mb>         RAM in MB (default: 65536)
#   --disk <gb>        Disk in GB (default: 256)
#   --storage <name>   Proxmox storage name (default: large)
#   --model <url>      HuggingFace GGUF URL to download
#   --model-path <p>   Path to existing GGUF file inside the container
#   --no-model         Skip model download
#   --ctx-size <n>     Context window size (default: 8192)
#   --parallel <n>     Number of parallel request slots (default: 2)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Defaults
CTID=103
CT_CPU=8
CT_RAM=65536
CT_DISK=256
CT_STORAGE="large"
CT_MODEL_URL="https://huggingface.co/Jackrong/Qwen3.5-27B-Claude-4.6-Opus-Reasoning-Distilled-v2-GGUF/resolve/main/Qwen3.5-27B.Q4_K_M.gguf"
CT_MODEL_PATH="/opt/qwen35-27b-opus-v2-q4km.gguf"
CT_CTX_SIZE=32768
CT_PARALLEL=2
DEPLOY_ONLY=false

# =========================================================================
# Container-side configuration (runs inside the LXC)
# =========================================================================

configure() {
    err()  { echo "ERROR: $*" >&2; exit 1; }
    info() { echo "==> $*"; }

    info "Configuring llama.cpp server (Vulkan backend)"

    # -------------------------------------------------------------------
    # Install build dependencies
    # -------------------------------------------------------------------
    info "Installing build dependencies"
    apt-get update -qq
    apt-get install -y --no-install-recommends \
        cmake build-essential git pkg-config \
        libvulkan-dev glslc mesa-vulkan-drivers vulkan-tools \
        wget ca-certificates

    # -------------------------------------------------------------------
    # Build llama.cpp with Vulkan
    # -------------------------------------------------------------------
    local llama_dir="/opt/llama.cpp"
    if [[ ! -d "$llama_dir" ]]; then
        info "Cloning llama.cpp"
        git clone --depth 1 https://github.com/ggml-org/llama.cpp.git "$llama_dir"
    else
        info "Updating llama.cpp"
        git -C "$llama_dir" pull --ff-only 2>/dev/null || true
    fi

    info "Building llama.cpp with Vulkan backend"
    cmake -B "$llama_dir/build" -S "$llama_dir" \
        -DGGML_VULKAN=ON -DCMAKE_BUILD_TYPE=Release
    cmake --build "$llama_dir/build" --config Release -j"$(nproc)"

    info "llama.cpp built successfully"

    # -------------------------------------------------------------------
    # Download model (if URL provided and file doesn't exist)
    # -------------------------------------------------------------------
    if [[ -n "${CT_MODEL_URL:-}" && ! -f "$CT_MODEL_PATH" ]]; then
        info "Downloading model to $CT_MODEL_PATH"
        mkdir -p "$(dirname "$CT_MODEL_PATH")"
        wget --progress=dot:giga "$CT_MODEL_URL" -O "$CT_MODEL_PATH"
        info "Model downloaded"
    elif [[ -f "$CT_MODEL_PATH" ]]; then
        info "Model already exists at $CT_MODEL_PATH"
    fi

    # -------------------------------------------------------------------
    # Disable Ollama if present (migration from previous setup)
    # -------------------------------------------------------------------
    if systemctl is-enabled ollama &>/dev/null; then
        info "Disabling Ollama (replaced by llama-server)"
        systemctl stop ollama 2>/dev/null || true
        systemctl disable ollama 2>/dev/null || true
    fi

    # -------------------------------------------------------------------
    # Configure llama-server systemd service
    # -------------------------------------------------------------------
    info "Configuring llama-server service"
    cat > /etc/systemd/system/llama-server.service <<EOF
[Unit]
Description=llama.cpp Server (Vulkan)
After=network.target

[Service]
Type=simple
ExecStart=${llama_dir}/build/bin/llama-server \\
    --model ${CT_MODEL_PATH} \\
    --gpu-layers 99 \\
    --ctx-size ${CT_CTX_SIZE} \\
    --host 0.0.0.0 \\
    --port 8080 \\
    --alias qwen3.5-27b-opus-v2 \\
    --parallel ${CT_PARALLEL} \\
    --flash-attn on
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable llama-server
    systemctl restart llama-server

    # Wait for server to be ready
    info "Waiting for llama-server to start..."
    local attempts=0
    while ! curl -sf http://localhost:8080/v1/models &>/dev/null; do
        attempts=$((attempts + 1))
        if [[ $attempts -ge 60 ]]; then
            err "llama-server did not start within 60 seconds"
        fi
        sleep 1
    done

    # -------------------------------------------------------------------
    # Firewall: restrict to LAN only
    # -------------------------------------------------------------------
    info "Configuring firewall"
    apt-get install -y --no-install-recommends iptables

    # Flush any previous rules to be idempotent
    iptables -D INPUT -p tcp --dport 8080 -s 127.0.0.1 -j ACCEPT 2>/dev/null || true
    iptables -D INPUT -p tcp --dport 8080 -s 192.168.0.0/23 -j ACCEPT 2>/dev/null || true
    iptables -D INPUT -p tcp --dport 8080 -j DROP 2>/dev/null || true
    # Clean up old Ollama rules
    iptables -D INPUT -p tcp --dport 11434 -s 127.0.0.1 -j ACCEPT 2>/dev/null || true
    iptables -D INPUT -p tcp --dport 11434 -s 192.168.0.0/23 -j ACCEPT 2>/dev/null || true
    iptables -D INPUT -p tcp --dport 11434 -j DROP 2>/dev/null || true

    iptables -A INPUT -p tcp --dport 8080 -s 127.0.0.1 -j ACCEPT
    iptables -A INPUT -p tcp --dport 8080 -s 192.168.0.0/23 -j ACCEPT
    iptables -A INPUT -p tcp --dport 8080 -j DROP

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

    # Verify Vulkan sees the GPU
    if command -v vulkaninfo &>/dev/null; then
        local gpu_name
        gpu_name=$(vulkaninfo --summary 2>&1 | grep "deviceName" | head -1 | sed 's/.*= //')
        info "Vulkan GPU: ${gpu_name:-unknown}"
    fi

    # -------------------------------------------------------------------
    # Summary
    # -------------------------------------------------------------------
    local ip
    ip=$(hostname -I 2>/dev/null | awk '{print $1}') || ip="<CONTAINER_IP>"
    local model_id
    model_id=$(curl -sf http://localhost:8080/v1/models | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4) || model_id="unknown"

    cat <<SUMMARY

================================================================
llama-server is deployed.

  API:       http://${ip}:8080/v1
  Model:     ${model_id}
  Backend:   Vulkan (Mesa RADV)
  GPU:       AMD 7900XTX (amdgpu) via /dev/kfd + /dev/dri
  Context:   ${CT_CTX_SIZE} tokens
  Parallel:  ${CT_PARALLEL} slots

  Test:      curl http://${ip}:8080/v1/models
  Chat:      curl http://${ip}:8080/v1/chat/completions \\
               -H 'Content-Type: application/json' \\
               -d '{"model":"${model_id}","messages":[{"role":"user","content":"Hello"}]}'
================================================================
SUMMARY
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
            --model)        CT_MODEL_URL="${2:?--model requires a value}"; shift 2 ;;
            --model-path)   CT_MODEL_PATH="${2:?--model-path requires a value}"; shift 2 ;;
            --no-model)     CT_MODEL_URL=""; shift ;;
            --ctx-size)     CT_CTX_SIZE="${2:?--ctx-size requires a value}"; shift 2 ;;
            --parallel)     CT_PARALLEL="${2:?--parallel requires a value}"; shift 2 ;;
            --deploy-only)  DEPLOY_ONLY=true; shift ;;
            *)              err "Unknown option: $1" ;;
        esac
    done

    info "llama.cpp LXC Setup"
    echo "  CTID:     ${CTID}"
    echo "  CPU:      ${CT_CPU} cores"
    echo "  RAM:      ${CT_RAM} MB ($((CT_RAM / 1024)) GB)"
    echo "  Disk:     ${CT_DISK} GB"
    echo "  Storage:  ${CT_STORAGE}"
    echo "  Model:    ${CT_MODEL_URL:-none (use --model-path)}"
    echo "  Context:  ${CT_CTX_SIZE}"
    echo "  Parallel: ${CT_PARALLEL}"
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
    elif create_lxc "$CTID" "llm" "$ip" "$CT_RAM" "$CT_CPU" "$CT_DISK" "$ROUTER_GW" "yes"; then
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
    info "Deploying llama-server configuration into CT ${CTID}"
    pct push "$CTID" "$0" /root/11-setup-ollama.sh --perms 0755
    pct exec "$CTID" -- bash -c \
        "CT_MODEL_URL='${CT_MODEL_URL}' CT_MODEL_PATH='${CT_MODEL_PATH}' CT_CTX_SIZE='${CT_CTX_SIZE}' CT_PARALLEL='${CT_PARALLEL}' DEBIAN_FRONTEND=noninteractive /root/11-setup-ollama.sh --configure"

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
    if grep -q "# GPU passthrough" "$conf" 2>/dev/null; then
        info "Removing old GPU passthrough config"
        sed -i '/# GPU passthrough/,$ d' "$conf"
    fi

    cat >> "$conf" <<'EOF'

# GPU passthrough (llama.cpp Vulkan)
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
