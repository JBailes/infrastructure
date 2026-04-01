#!/usr/bin/env bash
# pve-destroy-hosts.sh -- Destroy WOL LXC containers and VMs on Proxmox
#
# Runs on: the Proxmox host
# Stops and destroys hosts defined in inventory.conf so you can
# re-run pve-create-hosts.sh from scratch.
#
# Also cleans up:
#   - SSH known_hosts entries for destroyed hosts
#   - deploy-state.log (bootstrap progress tracker, on full teardown only)
#   (Proxmox host observability is managed by homelab/bootstrap/09-setup-proxmox-obs.sh)
#
# Does NOT remove:
#   - The apt-cache host (managed by homelab, not WOL)
#   - The vmbr1 bridge or any Proxmox host networking
#   - The LXC template or cloud image
#   - The storage pool
#
# Usage:
#   ./pve-destroy-hosts.sh              # Destroy all WOL hosts
#   ./pve-destroy-hosts.sh --host db    # Destroy a single host
#   ./pve-destroy-hosts.sh --env prod   # Destroy only prod per-env hosts
#   ./pve-destroy-hosts.sh --env test   # Destroy only test per-env hosts
#   ./pve-destroy-hosts.sh --yes        # Skip confirmation prompt

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

TARGET_HOST=""
TARGET_ENV=""
SKIP_CONFIRM=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)
            TARGET_HOST="${2:-}"
            [[ -z "$TARGET_HOST" ]] && err "Usage: $0 --host <hostname>"
            shift 2
            ;;
        --env)
            TARGET_ENV="${2:-}"
            [[ -z "$TARGET_ENV" ]] && err "Usage: $0 --env <prod|test>"
            shift 2
            ;;
        --yes)
            SKIP_CONFIRM=1
            shift
            ;;
        *)
            err "Unknown option: $1"
            ;;
    esac
done

[[ -n "$TARGET_HOST" && -n "$TARGET_ENV" ]] && err "--host and --env are mutually exclusive"

# ---------------------------------------------------------------------------
# Environment filtering helper
# ---------------------------------------------------------------------------

# Returns 0 if the host should be included in the destroy set.
should_destroy() {
    local name="$1"
    if [[ -n "$TARGET_HOST" ]]; then
        [[ "$name" == "$TARGET_HOST" ]] && return 0 || return 1
    fi
    if [[ -n "$TARGET_ENV" ]]; then
        # Only destroy per-env hosts matching the target environment suffix
        [[ "$name" == *-"${TARGET_ENV}" ]] && return 0 || return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Confirmation
# ---------------------------------------------------------------------------

if [[ $SKIP_CONFIRM -eq 0 ]]; then
    local_hosts=()
    for entry in "${HOSTS[@]}"; do
        parse_host "$entry"
        should_destroy "$H_NAME" && local_hosts+=("$entry")
    done

    if [[ ${#local_hosts[@]} -eq 0 ]]; then
        echo "No hosts match the given filter."
        exit 0
    fi

    if [[ -n "$TARGET_HOST" ]]; then
        echo "This will STOP and DESTROY host: $TARGET_HOST"
    elif [[ -n "$TARGET_ENV" ]]; then
        echo "This will STOP and DESTROY all '$TARGET_ENV' environment hosts:"
    else
        echo "This will STOP and DESTROY ALL ${#HOSTS[@]} WOL hosts:"
    fi

    for entry in "${local_hosts[@]}"; do
        parse_host "$entry"
        printf "  %-20s  %s %s\n" "$H_NAME" "$H_TYPE" "$H_CTID"
    done

    echo ""
    echo "This cannot be undone. All data on these hosts will be lost."
    read -rp "Type 'yes' to confirm: " confirm
    [[ "$confirm" == "yes" ]] || { echo "Aborted."; exit 1; }
fi

# ---------------------------------------------------------------------------
# Destroy functions
# ---------------------------------------------------------------------------

destroy_lxc() {
    local ctid="$1" name="$2"

    if ! pct status "$ctid" &>/dev/null; then
        info "SKIP: CT $ctid ($name) does not exist"
        return
    fi

    local status
    status=$(pct status "$ctid" | awk '{print $2}')
    if [[ "$status" == "running" ]]; then
        info "Stopping CT $ctid ($name)..."
        pct stop "$ctid" 2>/dev/null || true
    fi

    info "Destroying CT $ctid ($name)..."
    pct destroy "$ctid" --purge 2>/dev/null || pct destroy "$ctid"
    info "DESTROYED: CT $ctid ($name)"
}

destroy_vm() {
    local vmid="$1" name="$2"

    if ! qm status "$vmid" &>/dev/null; then
        info "SKIP: VM $vmid ($name) does not exist"
        return
    fi

    local status
    status=$(qm status "$vmid" | awk '{print $2}')
    if [[ "$status" == "running" ]]; then
        info "Stopping VM $vmid ($name)..."
        qm stop "$vmid" 2>/dev/null || true
    fi

    info "Destroying VM $vmid ($name)..."
    qm destroy "$vmid" --purge 2>/dev/null || qm destroy "$vmid"
    info "DESTROYED: VM $vmid ($name)"
}

# ---------------------------------------------------------------------------
# Clean up SSH known_hosts
# ---------------------------------------------------------------------------

cleanup_known_hosts() {
    local ip="$1" name="$2"
    if [[ -f /root/.ssh/known_hosts ]]; then
        ssh-keygen -R "$ip" 2>/dev/null || true
        ssh-keygen -R "$name" 2>/dev/null || true
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    info "WOL Infrastructure Teardown"

    # Build list of hosts to destroy (resolve CTIDs once upfront so we
    # never re-query pct list / qm list during stop/destroy phases).
    local targets=()
    for (( i=${#HOSTS[@]}-1; i>=0; i-- )); do
        parse_host "${HOSTS[$i]}"
        should_destroy "$H_NAME" || continue
        [[ -z "$H_CTID" ]] && { warn "Could not resolve CTID for $H_NAME, skipping"; continue; }
        # Bake the resolved CTID into the entry so parse_host won't re-resolve
        local resolved="${HOSTS[$i]/auto/$H_CTID}"
        targets+=("$resolved")
    done

    # Full teardown: also include the offline root CA container
    if [[ -z "$TARGET_HOST" && -z "$TARGET_ENV" ]]; then
        local ca_ctid
        ca_ctid=$(resolve_ctid "wol-root-ca") || true
        if [[ -n "$ca_ctid" ]]; then
            targets+=("wol-root-ca|${ca_ctid}|lxc|10.0.0.99||||2|256|1|||Offline root CA")
        fi
    fi

    if [[ ${#targets[@]} -eq 0 ]]; then
        info "Nothing to destroy"
        return
    fi

    # Phase 1: Stop all in parallel
    info "Stopping all hosts..."
    for entry in "${targets[@]}"; do
        parse_host "$entry"
        if [[ "$H_TYPE" == "lxc" ]]; then
            local status
            status=$(pct status "$H_CTID" 2>/dev/null | awk '{print $2}') || true
            if [[ "$status" == "running" ]]; then
                info "Stopping CT $H_CTID ($H_NAME)..."
                pct stop "$H_CTID" 2>/dev/null &
            fi
        elif [[ "$H_TYPE" == "vm" ]]; then
            local status
            status=$(qm status "$H_CTID" 2>/dev/null | awk '{print $2}') || true
            if [[ "$status" == "running" ]]; then
                info "Stopping VM $H_CTID ($H_NAME)..."
                qm stop "$H_CTID" 2>/dev/null &
            fi
        fi
    done
    wait

    # Verify all targets are fully stopped before destroying.
    # pct stop / qm stop may return before the container is fully down.
    info "Verifying all hosts are stopped..."
    for attempt in $(seq 1 30); do
        local all_stopped=1
        for entry in "${targets[@]}"; do
            parse_host "$entry"
            [[ -z "$H_CTID" ]] && continue
            local status=""
            if [[ "$H_TYPE" == "lxc" ]]; then
                status=$(pct status "$H_CTID" 2>/dev/null | awk '{print $2}') || true
            elif [[ "$H_TYPE" == "vm" ]]; then
                status=$(qm status "$H_CTID" 2>/dev/null | awk '{print $2}') || true
            fi
            if [[ "$status" == "running" ]]; then
                all_stopped=0
                break
            fi
        done
        [[ $all_stopped -eq 1 ]] && break
        sleep 2
    done
    info "All hosts stopped"

    # Phase 2: Destroy all in parallel
    info "Destroying all hosts..."
    for entry in "${targets[@]}"; do
        parse_host "$entry"
        if [[ "$H_TYPE" == "lxc" ]]; then
            if pct status "$H_CTID" &>/dev/null; then
                info "Destroying CT $H_CTID ($H_NAME)..."
                (pct destroy "$H_CTID" --purge 2>/dev/null || pct destroy "$H_CTID" 2>/dev/null || true) &
            fi
        elif [[ "$H_TYPE" == "vm" ]]; then
            if qm status "$H_CTID" &>/dev/null; then
                info "Destroying VM $H_CTID ($H_NAME)..."
                (qm destroy "$H_CTID" --purge 2>/dev/null || qm destroy "$H_CTID" 2>/dev/null || true) &
            fi
        fi
    done
    wait
    info "All hosts destroyed"

    # Phase 3: Clean up SSH known_hosts
    for entry in "${targets[@]}"; do
        parse_host "$entry"
        cleanup_known_hosts "$H_IP" "$H_NAME"
        if [[ -n "$H_EXT_IP" ]]; then
            cleanup_known_hosts "$H_EXT_IP" "$H_NAME"
        fi
    done

    # Always clear CA output and deploy state (stale after any teardown)
    local ca_output="$SCRIPT_DIR/ca-output"
    if [[ -d "$ca_output" ]]; then
        rm -rf "$ca_output"
        info "Cleared CA output directory"
    fi
    if [[ -f "$STATE_FILE" ]]; then
        rm -f "$STATE_FILE"
        info "Cleared deploy state log"
    fi
    rm -f "$SCRIPT_DIR"/deploy-*.log 2>/dev/null

    info "Teardown complete."
}

main "$@"
