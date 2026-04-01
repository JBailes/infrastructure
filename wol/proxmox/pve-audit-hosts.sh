#!/usr/bin/env bash
# pve-audit-hosts.sh -- Drift audit: compare live Proxmox config vs inventory
#
# Runs on: the Proxmox host
# Compares each host's live configuration (CPU, RAM, disk, network) against
# the values defined in inventory.conf. Reports mismatches.
#
# Usage:
#   ./pve-audit-hosts.sh              # Audit all hosts
#   ./pve-audit-hosts.sh --strict     # Exit non-zero on any mismatch (for CI gates)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

STRICT=0
[[ "${1:-}" == "--strict" ]] && STRICT=1

MISMATCHES=0

# ---------------------------------------------------------------------------
# Audit functions
# ---------------------------------------------------------------------------

audit_lxc() {
    parse_host "$1"
    local ctid="$H_CTID"

    if ! pct status "$ctid" &>/dev/null; then
        warn "$H_NAME (CT $ctid): does not exist"
        MISMATCHES=$((MISMATCHES + 1))
        return
    fi

    local live_ram live_cores live_disk
    live_ram=$(pct config "$ctid" | grep "^memory:" | awk '{print $2}')
    live_cores=$(pct config "$ctid" | grep "^cores:" | awk '{print $2}')
    live_disk=$(pct config "$ctid" | grep "^rootfs:" | grep -oP 'size=\K[0-9]+')

    [[ "$live_ram" == "$H_RAM_MB" ]] || { warn "$H_NAME: RAM mismatch (live=$live_ram, inventory=$H_RAM_MB)"; MISMATCHES=$((MISMATCHES + 1)); }
    [[ "$live_cores" == "$H_CORES" ]] || { warn "$H_NAME: cores mismatch (live=$live_cores, inventory=$H_CORES)"; MISMATCHES=$((MISMATCHES + 1)); }
    [[ "${live_disk:-0}" == "$H_DISK_GB" ]] || { warn "$H_NAME: disk mismatch (live=${live_disk:-?}G, inventory=${H_DISK_GB}G)"; MISMATCHES=$((MISMATCHES + 1)); }

    # Check boot ordering
    local live_startup
    live_startup=$(pct config "$ctid" | grep "^startup:" | awk '{print $2}') || true
    if [[ -z "$live_startup" ]]; then
        warn "$H_NAME: no boot ordering configured (onboot/startup missing)"
        MISMATCHES=$((MISMATCHES + 1))
    fi
}

audit_vm() {
    parse_host "$1"
    local vmid="$H_CTID"

    if ! qm status "$vmid" &>/dev/null; then
        warn "$H_NAME (VM $vmid): does not exist"
        MISMATCHES=$((MISMATCHES + 1))
        return
    fi

    local live_ram live_cores
    live_ram=$(qm config "$vmid" | grep "^memory:" | awk '{print $2}')
    live_cores=$(qm config "$vmid" | grep "^cores:" | awk '{print $2}')

    [[ "$live_ram" == "$H_RAM_MB" ]] || { warn "$H_NAME: RAM mismatch (live=$live_ram, inventory=$H_RAM_MB)"; MISMATCHES=$((MISMATCHES + 1)); }
    [[ "$live_cores" == "$H_CORES" ]] || { warn "$H_NAME: cores mismatch (live=$live_cores, inventory=$H_CORES)"; MISMATCHES=$((MISMATCHES + 1)); }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    info "WOL Infrastructure Drift Audit"
    info "Inventory: $INVENTORY"

    for entry in "${HOSTS[@]}"; do
        parse_host "$entry"
        if [[ "$H_TYPE" == "lxc" ]]; then
            audit_lxc "$entry"
        elif [[ "$H_TYPE" == "vm" ]]; then
            audit_vm "$entry"
        fi
    done

    echo ""
    if [[ $MISMATCHES -eq 0 ]]; then
        info "No drift detected. All hosts match inventory."
    else
        warn "$MISMATCHES mismatch(es) detected."
        if [[ $STRICT -eq 1 ]]; then
            err "Audit failed in strict mode. Fix drift before deploying."
        fi
    fi
}

main "$@"
