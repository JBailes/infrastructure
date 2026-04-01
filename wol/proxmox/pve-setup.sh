#!/usr/bin/env bash
# pve-setup.sh -- Single orchestrator to set up the entire WOL infrastructure
#
# Runs on: the Proxmox host
#
# This is the only script you need to run. It handles everything:
#   1. Proxmox host preparation (bridge, IP forwarding, SSH key, templates)
#   2. Container/VM creation (with VLAN tags)
#   3. Bootstrap deployment (shared infra, then per-env services)
#
# Usage:
#   ./pve-setup.sh                    # Deploy everything (shared + prod + test)
#   ./pve-setup.sh --skip-env prod    # Deploy everything except prod
#   ./pve-setup.sh --skip-env test    # Deploy everything except test
#   ./pve-setup.sh --only-env prod    # Deploy shared + prod only
#   ./pve-setup.sh --only-env test    # Deploy shared + test only
#   ./pve-setup.sh --only-shared      # Deploy shared infrastructure only
#
# Options:
#   --force           Override dependency checks in deploy
#   --skip-shared     Skip shared infrastructure (host prep, shared hosts)
#   --skip-host-prep  Skip Proxmox host preparation (already done)
#   --dry-run         Show what would be run without executing

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_DIR="$(cd "$SCRIPT_DIR/../bootstrap" && pwd)"

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo ""; echo "=================================================================="; echo "==> $*"; echo "=================================================================="; }
step() { echo ""; echo "--- $*"; }

[[ $EUID -eq 0 ]] || err "Run as root"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------

DEPLOY_PROD=1
DEPLOY_TEST=1
SKIP_SHARED=0
SKIP_HOST_PREP=0
FORCE=0
DRY_RUN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-env)
            [[ -z "${2:-}" ]] && err "Usage: $0 --skip-env <prod|test>"
            case "$2" in
                prod) DEPLOY_PROD=0 ;;
                test) DEPLOY_TEST=0 ;;
                *) err "Unknown environment: $2 (expected: prod or test)" ;;
            esac
            shift 2
            ;;
        --only-env)
            [[ -z "${2:-}" ]] && err "Usage: $0 --only-env <prod|test>"
            DEPLOY_PROD=0; DEPLOY_TEST=0
            case "$2" in
                prod) DEPLOY_PROD=1 ;;
                test) DEPLOY_TEST=1 ;;
                *) err "Unknown environment: $2 (expected: prod or test)" ;;
            esac
            shift 2
            ;;
        --only-shared) DEPLOY_PROD=0; DEPLOY_TEST=0; shift ;;
        --skip-shared)  SKIP_SHARED=1; shift ;;
        --skip-host-prep) SKIP_HOST_PREP=1; shift ;;
        --force)        FORCE=1; shift ;;
        --dry-run)      DRY_RUN=1; shift ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *) err "Unknown option: $1. Use --help for usage." ;;
    esac
done

# Build deploy/create flags
DEPLOY_FLAGS=()
CREATE_FLAGS=()
[[ $FORCE -eq 1 ]] && DEPLOY_FLAGS+=("--force")

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

run() {
    step "$1"
    shift
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "  DRY RUN: $*"
    else
        "$@"
    fi
}

elapsed() {
    local t=$SECONDS
    printf '%dh %dm %ds' $((t/3600)) $((t%3600/60)) $((t%60))
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    local start_time=$SECONDS

    echo ""
    echo "  WOL Infrastructure Setup"
    echo ""
    local envs=""
    [[ $DEPLOY_PROD -eq 1 ]] && envs="${envs:+$envs + }prod"
    [[ $DEPLOY_TEST -eq 1 ]] && envs="${envs:+$envs + }test"
    if [[ $SKIP_SHARED -eq 1 ]]; then
        echo "  Mode:  ${envs:-no environments} (shared skipped)"
    elif [[ -n "$envs" ]]; then
        echo "  Mode:  shared + $envs"
    else
        echo "  Mode:  shared infrastructure only"
    fi
    echo ""

    # -----------------------------------------------------------------------
    # Phase 1: Proxmox host preparation
    # -----------------------------------------------------------------------

    if [[ $SKIP_SHARED -eq 0 && $SKIP_HOST_PREP -eq 0 ]]; then
        info "Phase 1: Proxmox host preparation"
        run "Setting up Proxmox host (bridge, forwarding, SSH key, templates)" \
            "$SCRIPT_DIR/00-setup-proxmox-host.sh"
    fi

    # -----------------------------------------------------------------------
    # Phase 2: Create containers and VMs
    # -----------------------------------------------------------------------

    info "Phase 2: Create containers and VMs"

    if [[ $SKIP_SHARED -eq 0 ]]; then
        run "Creating shared infrastructure hosts (CTIDs 200-208)" \
            "$SCRIPT_DIR/pve-create-hosts.sh" "${CREATE_FLAGS[@]+"${CREATE_FLAGS[@]}"}"
    fi

    if [[ $DEPLOY_PROD -eq 1 ]]; then
        run "Creating prod environment hosts (CTIDs 209-212, VLAN 10)" \
            "$SCRIPT_DIR/pve-create-hosts.sh" --env prod "${CREATE_FLAGS[@]+"${CREATE_FLAGS[@]}"}"
    fi
    if [[ $DEPLOY_TEST -eq 1 ]]; then
        run "Creating test environment hosts (CTIDs 213-216, VLAN 20)" \
            "$SCRIPT_DIR/pve-create-hosts.sh" --env test "${CREATE_FLAGS[@]+"${CREATE_FLAGS[@]}"}"
    fi

    # -----------------------------------------------------------------------
    # Phase 3: Bootstrap deployment
    # -----------------------------------------------------------------------

    info "Phase 3: Bootstrap deployment"

    if [[ $SKIP_SHARED -eq 0 ]]; then
        run "Deploying shared infrastructure" \
            "$SCRIPT_DIR/pve-deploy.sh" "${DEPLOY_FLAGS[@]+"${DEPLOY_FLAGS[@]}"}"
    fi

    if [[ $DEPLOY_PROD -eq 1 ]]; then
        run "Deploying prod environment" \
            "$SCRIPT_DIR/pve-deploy.sh" --env prod "${DEPLOY_FLAGS[@]+"${DEPLOY_FLAGS[@]}"}"
    fi
    if [[ $DEPLOY_TEST -eq 1 ]]; then
        run "Deploying test environment" \
            "$SCRIPT_DIR/pve-deploy.sh" --env test "${DEPLOY_FLAGS[@]+"${DEPLOY_FLAGS[@]}"}"
    fi

    # -----------------------------------------------------------------------
    # Done
    # -----------------------------------------------------------------------

    SECONDS=$((SECONDS - start_time + SECONDS - SECONDS))
    info "Setup complete ($(elapsed))"

    echo ""
    local deployed="Shared infrastructure"
    [[ $DEPLOY_PROD -eq 1 ]] && deployed="$deployed + prod"
    [[ $DEPLOY_TEST -eq 1 ]] && deployed="$deployed + test"
    [[ $SKIP_SHARED -eq 1 ]] && deployed="${envs:-nothing}"
    echo "  Deployed: $deployed"
    echo ""
    echo "  Grafana:   http://192.168.1.100"
    echo "  Game port: 192.168.1.208:6969"
    echo ""
}

main "$@"
