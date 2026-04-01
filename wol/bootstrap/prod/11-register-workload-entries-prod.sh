#!/usr/bin/env bash
# 12-register-workload-entries-prod.sh -- Register SPIRE workload entries (prod)
#
# Runs on: spire-server (10.0.0.204) -- prod environment only
# Run order: Step 10 (all SPIRE Agents must be running and attested)
#
# This script is idempotent: existing entries are detected and skipped.
# Re-run after adding new service hosts.
#
# For join-token attestation (transitional), node IDs are:
#   spiffe://wol/node/<hostname>
# These are set when the join token is generated with -spiffeID.

set -euo pipefail

ENV_NAME="prod"

# Boot-time secret scrub: remove leftover .env.bootstrap from prior failed runs
_LIB="$(dirname "$0")/../lib/common.sh"; [[ -f "$_LIB" ]] || _LIB="/root/lib/common.sh"; source "$_LIB"
scrub_bootstrap_secrets

SPIRE_SERVER_BIN="${SPIRE_BIN_DIR:-/usr/local/bin}/spire-server"
SPIRE_SOCKET="/var/run/spire/server/private/api.sock"
TRUST_DOMAIN="wol"
WOL_ACCOUNTS_UID="1002"
WOL_ACCOUNTS_WRAPPER="/usr/lib/wol-accounts/Wol.Accounts"
WOL_ACCOUNTS_NODE="spiffe://${TRUST_DOMAIN}/node/wol-accounts"
WOL_WORLD_UID="1004"
WOL_WORLD_WRAPPER="/usr/lib/wol-world/Wol.World"
WOL_REALM_UID="1001"
WOL_REALM_WRAPPER="/usr/lib/wol-realm/bin/start"
WOL_AI_UID="1005"
WOL_AI_WRAPPER="/usr/lib/wol-ai/Wol.Ai"
WOL_SERVER_A_UID="1006"
WOL_SERVER_A_WRAPPER="/usr/lib/wol/bin/start"
WOL_SERVER_A_NODE="spiffe://${TRUST_DOMAIN}/node/wol-a"

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
ok()   { echo "  OK: $*"; }
skip() { echo "SKIP: $* (already registered)"; }

[[ $EUID -eq 0 ]] || err "Run as root"
[[ -x "$SPIRE_SERVER_BIN" ]] || err "spire-server binary not found at $SPIRE_SERVER_BIN"

# ---------------------------------------------------------------------------
# Helper: check if an entry with the given SPIFFE ID already exists
# ---------------------------------------------------------------------------

entry_exists() {
    local spiffe_id="$1"
    "$SPIRE_SERVER_BIN" entry show -socketPath "$SPIRE_SOCKET" -spiffeID "$spiffe_id" 2>/dev/null | grep -q "SPIFFE ID"
}

# ---------------------------------------------------------------------------
# Helper: create entry if it does not already exist
# ---------------------------------------------------------------------------

ensure_entry() {
    local spiffe_id="$1"
    shift
    if entry_exists "$spiffe_id"; then
        skip "$spiffe_id"
    else
        "$SPIRE_SERVER_BIN" entry create -socketPath "$SPIRE_SOCKET" -spiffeID "$spiffe_id" "$@"
        ok "Registered: $spiffe_id"
    fi
}

# ---------------------------------------------------------------------------
# Check SPIRE Server is reachable
# ---------------------------------------------------------------------------

check_spire_healthy() {
    info "Checking SPIRE Server health"
    curl -sf http://localhost:8080/ready &>/dev/null \
        || err "SPIRE Server not ready. Check: systemctl status spire-server"
    info "SPIRE Server is ready"
}

# ---------------------------------------------------------------------------
# Register node entries (one per host)
# Node entries establish the parent to child relationship
# ---------------------------------------------------------------------------

register_node_entries() {
    info "Registering node entries"

    # Node entries are created automatically by the join_token attestor.
    # The join_token generates a node SPIFFE ID in the format spiffe://wol/spire/agent/join_token/<token>
    # We re-map these to friendly node IDs using the -spiffeID flag during token generation.
    # Verify registered nodes:
    "$SPIRE_SERVER_BIN" agent list -socketPath "$SPIRE_SOCKET" 2>/dev/null || info "(agent list requires agent connection)"
}

# ---------------------------------------------------------------------------
# wol-accounts service entry
# ---------------------------------------------------------------------------

register_accounts_entry() {
    info "Registering wol-accounts workload entry"
    ensure_entry "spiffe://${TRUST_DOMAIN}/accounts" \
        -parentID "$WOL_ACCOUNTS_NODE" \
        -selector "unix:uid:${WOL_ACCOUNTS_UID}" \
        -selector "unix:path:${WOL_ACCOUNTS_WRAPPER}" \
        -x509SVIDTTL 3600 \
        -jwtSVIDTTL 300

    info "wol-accounts SVID: spiffe://$TRUST_DOMAIN/accounts"
    info "  Selector: unix:uid=$WOL_ACCOUNTS_UID AND unix:path=$WOL_ACCOUNTS_WRAPPER"
}

# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# wol-world service entry
# ---------------------------------------------------------------------------

register_world_entry() {
    local env_name="$1"  # "prod" or "test"
    local node_id="spiffe://${TRUST_DOMAIN}/node/wol-world-${env_name}"
    local spiffe_id="spiffe://${TRUST_DOMAIN}/world-${env_name}"

    info "Registering wol-world-${env_name} workload entry"
    ensure_entry "$spiffe_id" \
        -parentID "$node_id" \
        -selector "unix:uid:${WOL_WORLD_UID}" \
        -selector "unix:path:${WOL_WORLD_WRAPPER}" \
        -x509SVIDTTL 3600 \
        -jwtSVIDTTL 300

    info "wol-world-${env_name} SVID: $spiffe_id"
    info "  Selector: unix:uid=$WOL_WORLD_UID AND unix:path=$WOL_WORLD_WRAPPER"
}

# ---------------------------------------------------------------------------
# wol-ai service entry
# ---------------------------------------------------------------------------

register_ai_entry() {
    local env_name="$1"  # "prod" or "test"
    local node_id="spiffe://${TRUST_DOMAIN}/node/wol-ai-${env_name}"
    local spiffe_id="spiffe://${TRUST_DOMAIN}/ai-${env_name}"

    info "Registering wol-ai-${env_name} workload entry"
    ensure_entry "$spiffe_id" \
        -parentID "$node_id" \
        -selector "unix:uid:${WOL_AI_UID}" \
        -selector "unix:path:${WOL_AI_WRAPPER}" \
        -x509SVIDTTL 3600 \
        -jwtSVIDTTL 300

    info "wol-ai-${env_name} SVID: $spiffe_id"
    info "  Selector: unix:uid=$WOL_AI_UID AND unix:path=$WOL_AI_WRAPPER"
}

# ---------------------------------------------------------------------------
# WOL realm entries (template, add one per realm host)
# ---------------------------------------------------------------------------

register_realm_entry() {
    local realm_hostname="$1"   # e.g. "wol-realm-prod" (the LXC hostname)
    local realm_id="$2"         # e.g. "realm-a" (short name for SPIFFE ID)
    local realm_uid="$3"        # e.g. "1001"
    local realm_wrapper="$4"    # e.g. "/usr/lib/wol-realm/bin/start"
    local realm_node="spiffe://${TRUST_DOMAIN}/node/${realm_hostname}"
    local spiffe_id="spiffe://${TRUST_DOMAIN}/${realm_id}"

    info "Registering $realm_hostname workload entry"
    ensure_entry "$spiffe_id" \
        -parentID "$realm_node" \
        -selector "unix:uid:${realm_uid}" \
        -selector "unix:path:${realm_wrapper}" \
        -x509SVIDTTL 3600 \
        -jwtSVIDTTL 300
    info "$realm_hostname SVID: $spiffe_id"
}

# ---------------------------------------------------------------------------
# WOL server entries (connection interface, template for autoscaling)
# ---------------------------------------------------------------------------

register_server_entry() {
    local server_hostname="$1"  # e.g. "wol-a" (the LXC hostname)
    local server_id="$2"        # e.g. "server-a" (short name for SPIFFE ID)
    local server_uid="$3"       # e.g. "1006"
    local server_wrapper="$4"   # e.g. "/usr/lib/wol/bin/start"
    local server_node="spiffe://${TRUST_DOMAIN}/node/${server_hostname}"
    local spiffe_id="spiffe://${TRUST_DOMAIN}/${server_id}"

    info "Registering $server_hostname workload entry"
    ensure_entry "$spiffe_id" \
        -parentID "$server_node" \
        -selector "unix:uid:${server_uid}" \
        -selector "unix:path:${server_wrapper}" \
        -x509SVIDTTL 3600 \
        -jwtSVIDTTL 300
    info "$server_hostname SVID: $spiffe_id"
}

# ---------------------------------------------------------------------------
# Print entry summary
# ---------------------------------------------------------------------------

print_summary() {
    info "Current workload entries:"
    "$SPIRE_SERVER_BIN" entry show -socketPath "$SPIRE_SOCKET" 2>/dev/null | grep -E "^(Entry ID|SPIFFE ID|Parent ID|Selector)" || true

    cat <<'EOF'

================================================================
Workload entries registered.

To verify an agent is receiving SVIDs, on any agent host run:
  /usr/local/bin/spire-agent api fetch x509 \
      -socketPath /var/run/spire/agent.sock

To add a new realm entry, call this script with:
  REALM_HOSTNAME=wol-realm-b REALM_ID=realm-b REALM_UID=1001 \
      REALM_WRAPPER=/usr/lib/wol-realm/bin/start \
      ./12-register-workload-entries.sh --realm

To add a new wol server entry, call this script with:
  SERVER_HOSTNAME=wol-b SERVER_ID=server-b SERVER_UID=1006 \
      SERVER_WRAPPER=/usr/lib/wol/bin/start \
      ./12-register-workload-entries.sh --server

To add the wol-accounts entry individually:
  ./12-register-workload-entries.sh --accounts
================================================================
EOF
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

register_env_entries() {
    local env="$1"
    register_world_entry "$env"
    register_ai_entry "$env"
    register_realm_entry "wol-realm-${env}" "realm-${env}" "$WOL_REALM_UID" "$WOL_REALM_WRAPPER"
}

main() {
    check_spire_healthy
    register_node_entries

    if [[ -n "${ENV_NAME:-}" ]]; then
        # Per-env deploy: register entries for the specified environment only
        register_env_entries "$ENV_NAME"
    else
        # Full deploy: register shared + all environments
        register_accounts_entry
        register_env_entries "prod"
        register_env_entries "test"
        register_server_entry "wol-a" "server-a" "$WOL_SERVER_A_UID" "$WOL_SERVER_A_WRAPPER"
    fi

    print_summary
}

case "${1:-}" in
    --accounts)
        check_spire_healthy
        register_accounts_entry
        ;;
    --world)
        : "${ENV_NAME:?Set ENV_NAME (prod or test)}"
        check_spire_healthy
        register_world_entry "$ENV_NAME"
        ;;
    --ai)
        : "${ENV_NAME:?Set ENV_NAME (prod or test)}"
        check_spire_healthy
        register_ai_entry "$ENV_NAME"
        ;;
    --realm)
        : "${REALM_HOSTNAME:?Set REALM_HOSTNAME (e.g. wol-realm-b)}"
        : "${REALM_ID:?Set REALM_ID (e.g. realm-b)}"
        : "${REALM_UID:?Set REALM_UID}"
        : "${REALM_WRAPPER:?Set REALM_WRAPPER}"
        check_spire_healthy
        register_realm_entry "$REALM_HOSTNAME" "$REALM_ID" "$REALM_UID" "$REALM_WRAPPER"
        ;;
    --server)
        : "${SERVER_HOSTNAME:?Set SERVER_HOSTNAME (e.g. wol-b)}"
        : "${SERVER_ID:?Set SERVER_ID (e.g. server-b)}"
        : "${SERVER_UID:?Set SERVER_UID}"
        : "${SERVER_WRAPPER:?Set SERVER_WRAPPER}"
        check_spire_healthy
        register_server_entry "$SERVER_HOSTNAME" "$SERVER_ID" "$SERVER_UID" "$SERVER_WRAPPER"
        ;;
    "")
        main
        ;;
    *)
        err "Usage: $0 [--accounts | --world | --ai | --realm | --server]"
        ;;
esac
