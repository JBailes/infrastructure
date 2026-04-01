#!/usr/bin/env bash
# common.sh -- Shared functions for Proxmox provisioning scripts
# Sourced by pve-create-hosts.sh, pve-deploy.sh, pve-audit-hosts.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INVENTORY="$SCRIPT_DIR/inventory.conf"
STATE_FILE="$SCRIPT_DIR/deploy-state.log"

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
warn() { echo "WARN: $*" >&2; }

# Source inventory
# shellcheck source=../inventory.conf
[[ -f "$INVENTORY" ]] || err "Inventory not found: $INVENTORY"
source "$INVENTORY"

# ---------------------------------------------------------------------------
# CTID allocation and resolution
# ---------------------------------------------------------------------------

# Find the first free CTID >= start by querying Proxmox
next_free_ctid() {
    local start="${1:?Usage: next_free_ctid <start>}"
    local used
    used=$(
        { pct list 2>/dev/null | awk 'NR>1{print $1}'; \
          qm list 2>/dev/null | awk 'NR>1{print $1}'; } | sort -n
    )
    local ctid="$start"
    while echo "$used" | grep -qw "$ctid"; do
        ctid=$((ctid + 1))
    done
    echo "$ctid"
}

# Resolve a hostname to its CTID by querying Proxmox
resolve_ctid() {
    local name="${1:?Usage: resolve_ctid <hostname>}"
    local ctid
    ctid=$(pct list 2>/dev/null | awk -v h="$name" '$3 == h {print $1; exit}') || true
    if [[ -n "$ctid" ]]; then echo "$ctid"; return 0; fi
    ctid=$(qm list 2>/dev/null | awk -v h="$name" '$2 == h {print $1; exit}') || true
    if [[ -n "$ctid" ]]; then echo "$ctid"; return 0; fi
    return 1
}

# ---------------------------------------------------------------------------
# Host record parsing
# ---------------------------------------------------------------------------

# Parse a pipe-delimited host record into named variables
parse_host() {
    local record="$1"
    IFS='|' read -r H_NAME H_CTID H_TYPE H_IP H_BRIDGE_INT H_BRIDGE_EXT \
        H_PRIVILEGED H_DISK_GB H_RAM_MB H_CORES H_EXT_IP H_TEST_IP H_NOTES <<< "$record"
    if [[ "$H_CTID" == "auto" ]]; then
        H_CTID=$(resolve_ctid "$H_NAME") || true
    fi
}

# Look up a host by name (checks HOSTS first, then EXTERNAL_HOSTS)
lookup_host() {
    local name="$1"
    for entry in "${HOSTS[@]}"; do
        local hname
        hname=$(echo "$entry" | cut -d'|' -f1)
        if [[ "$hname" == "$name" ]]; then
            echo "$entry"
            return 0
        fi
    done
    for entry in "${EXTERNAL_HOSTS[@]+"${EXTERNAL_HOSTS[@]}"}"; do
        local hname
        hname=$(echo "$entry" | cut -d'|' -f1)
        if [[ "$hname" == "$name" ]]; then
            echo "$entry"
            return 0
        fi
    done
    return 1
}

# ---------------------------------------------------------------------------
# Deploy state tracking
# ---------------------------------------------------------------------------

record_step() {
    local step="$1" host="$2" script="$3"
    echo "$(date -Iseconds)|$step|$host|$script|OK" >> "$STATE_FILE"
}

step_completed() {
    local step="$1"
    grep -q "^.*|${step}|.*|OK$" "$STATE_FILE" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Checkpoint handling
# ---------------------------------------------------------------------------

checkpoint() {
    local msg="$1"
    local type="${2:-verification}"  # "mandatory" or "verification"
    echo ""
    echo "================================================================"
    echo "CHECKPOINT ($type): $msg"
    echo "================================================================"
    echo ""
    if [[ "$type" == "mandatory" ]]; then
        echo "MANDATORY: This checkpoint requires operator action. Cannot be skipped."
        echo "Press Enter to continue, or Ctrl-C to abort."
        read -r
        return
    fi
    if [[ "${UNATTENDED:-0}" == "1" ]]; then
        echo "UNATTENDED: skipping verification checkpoint (logged)"
        return
    fi
    echo "Press Enter to continue, or Ctrl-C to abort."
    read -r
}

# ---------------------------------------------------------------------------
# Remote execution
# ---------------------------------------------------------------------------

run_on_lxc() {
    local ctid="$1" script="$2" env_vars="$3"
    # Suppress debconf/dpkg interactive prompts (no TTY in pct exec)
    env_vars="${env_vars:+$env_vars }DEBIAN_FRONTEND=noninteractive TERM=dumb"
    local script_path="${BOOTSTRAP_DIR}/${script}"
    local script_basename
    script_basename=$(basename "$script")
    local remote_path="/root/${script_basename}"

    [[ -f "$script_path" ]] || err "Script not found: $script_path"

    # Push the shared bootstrap library (sourced by all scripts)
    local lib_path="${BOOTSTRAP_DIR}/lib/common.sh"
    if [[ -f "$lib_path" ]]; then
        pct exec "$ctid" -- mkdir -p /root/lib
        pct push "$ctid" "$lib_path" "/root/lib/common.sh" --perms 0755
    fi

    # Push apt proxy config (apt-cacher-ng on apt-cache, managed by homelab).
    # Skip for apt-cache (is the cache) and gateways (bootstrap before
    # apt-cache is reachable, they configure their own proxy later).
    local host_name
    host_name=$(pct config "$ctid" 2>/dev/null | grep "^hostname:" | awk '{print $2}') || true
    if [[ "$host_name" != "apt-cache" && "$host_name" != wol-gateway-* ]]; then
        if pct exec "$ctid" -- bash -c "timeout 3 bash -c 'echo > /dev/tcp/10.0.0.115/3142' 2>/dev/null" 2>/dev/null; then
            local tmp_proxy
            tmp_proxy=$(mktemp)
            cat > "$tmp_proxy" <<'APROXY'
Acquire::http::Proxy "http://10.0.0.115:3142";
APROXY
            pct exec "$ctid" -- mkdir -p /etc/apt/apt.conf.d
            pct push "$ctid" "$tmp_proxy" "/etc/apt/apt.conf.d/01proxy" --perms 0644
            rm -f "$tmp_proxy"
        else
            info "apt-cache not reachable from $host_name, skipping proxy config"
        fi
    fi

    pct push "$ctid" "$script_path" "$remote_path" --perms 0755

    # Execute with env vars (always has at least DEBIAN_FRONTEND and TERM)
    local tmp_env
    tmp_env=$(mktemp)
    echo "$env_vars" | tr ' ' '\n' > "$tmp_env"
    pct push "$ctid" "$tmp_env" "/root/.env.bootstrap" --perms 0600
    rm -f "$tmp_env"
    pct exec "$ctid" -- bash -c "trap 'rm -f /root/.env.bootstrap' EXIT; set -a; source /root/.env.bootstrap; set +a; $remote_path"
}

run_on_vm() {
    local ip="$1" script="$2" env_vars="$3"
    # Suppress debconf/dpkg interactive prompts (no TTY in SSH)
    env_vars="${env_vars:+$env_vars }DEBIAN_FRONTEND=noninteractive TERM=dumb"
    local script_path="${BOOTSTRAP_DIR}/${script}"
    local script_basename
    script_basename=$(basename "$script")
    local remote_path="/root/${script_basename}"

    [[ -f "$script_path" ]] || err "Script not found: $script_path"

    # Push the shared bootstrap library (sourced by all scripts)
    local lib_path="${BOOTSTRAP_DIR}/lib/common.sh"
    if [[ -f "$lib_path" ]]; then
        ssh -o StrictHostKeyChecking=accept-new "root@${ip}" "mkdir -p /root/lib"
        scp -o StrictHostKeyChecking=accept-new "$lib_path" "root@${ip}:/root/lib/common.sh"
    fi

    # Push apt proxy config only if apt-cache is reachable from the VM
    if ssh -o StrictHostKeyChecking=accept-new "root@${ip}" \
        "timeout 3 bash -c 'echo > /dev/tcp/10.0.0.115/3142' 2>/dev/null" 2>/dev/null; then
        ssh -o StrictHostKeyChecking=accept-new "root@${ip}" \
            "mkdir -p /etc/apt/apt.conf.d && echo 'Acquire::http::Proxy \"http://10.0.0.115:3142\";' > /etc/apt/apt.conf.d/01proxy"
    else
        info "apt-cache not reachable from VM at $ip, skipping proxy config"
    fi

    scp -o StrictHostKeyChecking=accept-new "$script_path" "root@${ip}:${remote_path}"

    # Execute with env vars
    local tmp_env
    tmp_env=$(mktemp)
    echo "$env_vars" | tr ' ' '\n' > "$tmp_env"
    scp -o StrictHostKeyChecking=accept-new "$tmp_env" "root@${ip}:/root/.env.bootstrap"
    rm -f "$tmp_env"
    ssh -o StrictHostKeyChecking=accept-new "root@${ip}" \
        "chmod 600 /root/.env.bootstrap && trap 'rm -f /root/.env.bootstrap' EXIT && set -a && source /root/.env.bootstrap && set +a && $remote_path"
}

# ---------------------------------------------------------------------------
# Secret scrub
# ---------------------------------------------------------------------------

scrub_secrets() {
    info "Running secret scrub across all hosts"
    local unsanitized=0
    for entry in "${HOSTS[@]}"; do
        parse_host "$entry"
        if [[ "$H_TYPE" == "lxc" ]]; then
            if pct status "$H_CTID" &>/dev/null; then
                pct exec "$H_CTID" -- rm -f /root/.env.bootstrap 2>/dev/null \
                    && info "Scrubbed: $H_NAME (CT $H_CTID)" \
                    || { warn "Could not scrub $H_NAME (CT $H_CTID)"; unsanitized=1; }
            else
                warn "Host $H_NAME (CT $H_CTID) not running, cannot scrub"
                unsanitized=1
            fi
        elif [[ "$H_TYPE" == "vm" ]]; then
            if ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 "root@${H_IP}" rm -f /root/.env.bootstrap 2>/dev/null; then
                info "Scrubbed: $H_NAME (VM $H_CTID)"
            else
                warn "Could not scrub $H_NAME (VM $H_CTID)"
                unsanitized=1
            fi
        fi
    done
    if [[ $unsanitized -ne 0 ]]; then
        warn "Some hosts could not be scrubbed. Deploy state: UNSANITIZED"
    else
        info "All hosts scrubbed successfully"
    fi
}
