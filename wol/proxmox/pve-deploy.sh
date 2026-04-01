#!/usr/bin/env bash
# pve-deploy.sh -- Run bootstrap scripts on WOL hosts in sequence
#
# Runs on: the Proxmox host
# Reads bootstrap sequences from inventory.conf and executes each script on its target host.
#
# Shared infrastructure and environments are deployed separately:
#   ./pve-deploy.sh              # Shared infrastructure only
#   ./pve-deploy.sh --env prod   # Prod environment (shared must be up)
#   ./pve-deploy.sh --env test   # Test environment (shared must be up)
#   ./pve-deploy.sh --all        # Shared + prod + test
#
# Filtering:
#   ./pve-deploy.sh --step 10               # Run only step 10
#   ./pve-deploy.sh --from 07               # Run from step 07 onward
#   ./pve-deploy.sh --host wol-accounts     # Run all steps for one host
#   ./pve-deploy.sh --unattended            # Skip verification checkpoints
#   ./pve-deploy.sh --force                 # Override dependency check
#   ./pve-deploy.sh --scrub                 # Run secret scrub only

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# Parse arguments
FILTER_STEP=""
FILTER_FROM=""
FILTER_HOST=""
FILTER_ENV=""
DEPLOY_ALL=0
UNATTENDED="${UNATTENDED:-0}"  # Deprecated (no manual checkpoints remain)
FORCE=0
SCRUB_ONLY=0
LOG_FILE="$SCRIPT_DIR/deploy-$(date +%Y-%m-%d).log"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --step) FILTER_STEP="$2"; shift 2 ;;
        --from) FILTER_FROM="$2"; shift 2 ;;
        --host) FILTER_HOST="$2"; shift 2 ;;
        --env)  FILTER_ENV="$2"; shift 2 ;;
        --all)  DEPLOY_ALL=1; shift ;;
        --unattended) UNATTENDED=1; shift ;;
        --force) FORCE=1; shift ;;
        --scrub) SCRUB_ONLY=1; shift ;;
        *) err "Unknown argument: $1" ;;
    esac
done

export UNATTENDED

# ---------------------------------------------------------------------------
# Scrub-only mode
# ---------------------------------------------------------------------------

if [[ $SCRUB_ONLY -eq 1 ]]; then
    scrub_secrets
    exit 0
fi

# ---------------------------------------------------------------------------
# Log redaction filter
# ---------------------------------------------------------------------------

# Pattern-based redaction (secondary safety net; primary control is no-secret-output at source)
redact() {
    sed -E \
        -e 's/(password|token|secret|key)=\S+/\1=[REDACTED]/gi' \
        -e 's/[A-Za-z0-9+/]{40,}=[=]*/[REDACTED-BASE64]/g'
}

# ---------------------------------------------------------------------------
# SPIRE join token generation and distribution
# ---------------------------------------------------------------------------

generate_spire_join_tokens() {
    local sequence_ref=("$@")
    info "Generating SPIRE join tokens for service hosts in this sequence"

    # Hosts that need SPIRE Agents (step 09 runs 09-setup-spire-agent.sh)
    local spire_hosts=()
    for entry in "${sequence_ref[@]}"; do
        local seq_step seq_host seq_script
        seq_step=$(echo "$entry" | cut -d'|' -f1)
        seq_host=$(echo "$entry" | cut -d'|' -f2)
        seq_script=$(echo "$entry" | cut -d'|' -f3)
        if [[ "$seq_script" == "09-setup-spire-agent.sh" ]]; then
            spire_hosts+=("$seq_host")
        fi
    done

    if [[ ${#spire_hosts[@]} -eq 0 ]]; then
        info "No SPIRE Agent hosts in this sequence"
        return
    fi

    # Find spire-server CTID
    local spire_entry
    spire_entry=$(lookup_host "spire-server") || err "spire-server not found in inventory"
    parse_host "$spire_entry"
    local spire_ctid="$H_CTID"
    local spire_type="$H_TYPE"
    local spire_ip="$H_IP"

    # Wait for spire-server to be ready (VM may still be booting)
    if [[ "$spire_type" == "vm" ]]; then
        info "Waiting for spire-server SSH to be ready..."
        local wait_attempt
        for wait_attempt in $(seq 1 30); do
            if ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=3 -o BatchMode=yes \
                "root@${spire_ip}" true &>/dev/null; then
                break
            fi
            sleep 2
        done
    fi

    for target_host in "${spire_hosts[@]}"; do
        local host_entry
        host_entry=$(lookup_host "$target_host") || { warn "Host $target_host not found in inventory, skipping token"; continue; }
        parse_host "$host_entry"
        local target_ctid="$H_CTID"
        local target_type="$H_TYPE"
        local target_ip="$H_IP"

        if [[ -z "$target_ctid" ]]; then
            err "Could not resolve CTID for $target_host. Is the host running?"
        fi

        info "Generating join token for $target_host (CTID $target_ctid, spiffe://wol/node/$target_host)"

        local token
        local spire_sock="/var/run/spire/server/private/api.sock"
        if [[ "$spire_type" == "vm" ]]; then
            token=$(ssh -o StrictHostKeyChecking=accept-new "root@${spire_ip}" \
                "spire-server token generate -socketPath ${spire_sock} -spiffeID spiffe://wol/node/${target_host} -ttl 600 2>/dev/null | grep 'Token:' | awk '{print \$2}'" 2>/dev/null) || true
        else
            token=$(pct exec "$spire_ctid" -- \
                spire-server token generate -socketPath "$spire_sock" -spiffeID "spiffe://wol/node/${target_host}" -ttl 600 2>/dev/null | grep 'Token:' | awk '{print $2}') || true
        fi

        if [[ -z "$token" ]]; then
            warn "Failed to generate token for $target_host. Generate manually on spire-server."
            continue
        fi

        # Write token to target host (temp file, consumed by SPIRE Agent on first start).
        # Create the directory first since the SPIRE agent install (step 09) hasn't run yet.
        local token_path="/var/lib/spire/agent/join_token"
        if [[ "$target_type" == "lxc" ]]; then
            pct exec "$target_ctid" -- mkdir -p /var/lib/spire/agent
            local tmp_token
            tmp_token=$(mktemp)
            echo "$token" > "$tmp_token"
            pct push "$target_ctid" "$tmp_token" "$token_path"
            pct exec "$target_ctid" -- chmod 600 "$token_path"
            pct exec "$target_ctid" -- chown root:root "$token_path"
            rm -f "$tmp_token"
        elif [[ "$target_type" == "vm" ]]; then
            ssh -o StrictHostKeyChecking=accept-new "root@${target_ip}" "mkdir -p /var/lib/spire/agent && echo '$token' > $token_path && chmod 600 $token_path"
        fi

        info "Token distributed to $target_host at $token_path"
    done

    info "All join tokens generated and distributed"
}

# ---------------------------------------------------------------------------
# Dependency validation
# ---------------------------------------------------------------------------

validate_dependencies() {
    local step="$1"
    if [[ $FORCE -eq 1 ]]; then
        warn "Dependency check skipped (--force)"
        return 0
    fi
    if [[ ! -f "$STATE_FILE" ]]; then
        if [[ "$step" != "00" ]]; then
            warn "No deploy state file found. Use --force to override."
            return 1
        fi
        return 0
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Automated verification checks (replace manual checkpoints)
# ---------------------------------------------------------------------------

# Verify NAT gateways are forwarding traffic by pinging 8.8.8.8 from a
# private-network host. Tries up to 30 seconds for the gateway to come up.
verify_nat_gateways() {
    info "Verifying NAT gateway connectivity from private network"

    # Find any running LXC on the private bridge to test from
    local test_ctid=""
    for entry in "${HOSTS[@]}"; do
        parse_host "$entry"
        if [[ "$H_TYPE" == "lxc" && -n "$H_BRIDGE_INT" && "$H_BRIDGE_INT" != "-" ]]; then
            if pct status "$H_CTID" 2>/dev/null | grep -q running; then
                test_ctid="$H_CTID"
                break
            fi
        fi
    done

    if [[ -z "$test_ctid" ]]; then
        warn "No running private-network host found to test NAT gateway. Skipping check."
        return 0
    fi

    local attempt
    for attempt in $(seq 1 6); do
        if pct exec "$test_ctid" -- ping -c1 -W3 8.8.8.8 &>/dev/null; then
            info "NAT gateway verified (ping 8.8.8.8 from CT $test_ctid succeeded)"
            return 0
        fi
        sleep 5
    done

    err "NAT gateway check failed: CT $test_ctid cannot reach 8.8.8.8 after 30s. Check gateway configuration."
}

# Verify all SPIRE agents are healthy by querying spire-server for agent list.
# Waits up to 60 seconds for agents to check in.
verify_spire_agents() {
    info "Verifying SPIRE agent health"

    local spire_entry
    spire_entry=$(lookup_host "spire-server") || { warn "spire-server not in inventory, skipping check"; return 0; }
    parse_host "$spire_entry"
    local spire_ctid="$H_CTID"
    local spire_type="$H_TYPE"
    local spire_ip="$H_IP"
    local spire_sock="/var/run/spire/server/private/api.sock"

    local agent_list
    local attempt
    for attempt in $(seq 1 12); do
        if [[ "$spire_type" == "vm" ]]; then
            agent_list=$(ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 "root@${spire_ip}" \
                "spire-server agent list -socketPath $spire_sock 2>/dev/null" 2>/dev/null) || true
        else
            agent_list=$(pct exec "$spire_ctid" -- \
                spire-server agent list -socketPath "$spire_sock" 2>/dev/null) || true
        fi

        if [[ -n "$agent_list" ]] && echo "$agent_list" | grep -q "spiffe://"; then
            local agent_count
            agent_count=$(echo "$agent_list" | grep -c "spiffe://" || true)
            info "SPIRE agents verified: $agent_count agent(s) registered"
            return 0
        fi
        sleep 5
    done

    warn "No SPIRE agents found after 60s. Agents may still be starting. Continuing deployment."
}

# ---------------------------------------------------------------------------
# SPIRE DB password retrieval
# ---------------------------------------------------------------------------

retrieve_spire_db_password() {
    if [[ -n "${SPIRE_DB_PASSWORD:-}" ]]; then
        return  # Already set (e.g. from environment or prior call)
    fi

    local db_entry db_ctid
    db_entry=$(lookup_host "spire-db") || { warn "spire-db not found in inventory"; return; }
    parse_host "$db_entry"
    db_ctid="$H_CTID"

    if ! pct status "$db_ctid" &>/dev/null; then
        warn "spire-db host (CT $db_ctid) not running, cannot retrieve SPIRE DB password"
        return
    fi

    SPIRE_DB_PASSWORD=$(pct exec "$db_ctid" -- cat /etc/wol-db-secrets/spire_password 2>/dev/null) || true
    if [[ -n "$SPIRE_DB_PASSWORD" ]]; then
        export SPIRE_DB_PASSWORD
        info "SPIRE DB password retrieved from db host (CT $db_ctid)"
    else
        warn "SPIRE DB password not found on db host. Step 02 may not have run yet."
        warn "If deploying spire-server, set SPIRE_DB_PASSWORD manually or run step 02 first."
    fi
}


# ---------------------------------------------------------------------------
# Run a bootstrap sequence
# ---------------------------------------------------------------------------

run_sequence() {
    local label="$1"
    shift
    local sequence=("$@")

    if [[ ${#sequence[@]} -eq 0 ]]; then
        info "No steps in $label sequence"
        return
    fi

    info "=== Deploying: $label ==="

    local tokens_generated=0
    local prev_step=""
    for entry in "${sequence[@]}"; do
        IFS='|' read -r step host script env_vars <<< "$entry"

        # Apply filters
        if [[ -n "$FILTER_STEP" && "$step" != "$FILTER_STEP" ]]; then continue; fi
        if [[ -n "$FILTER_FROM" && "$step" < "$FILTER_FROM" ]]; then continue; fi
        if [[ -n "$FILTER_HOST" && "$host" != "$FILTER_HOST" ]]; then continue; fi

        # Automated checks between steps (shared sequence only)
        if [[ "$prev_step" != "$step" ]]; then
            case "$step" in
                "01")
                    if [[ "$prev_step" == "00" ]]; then
                        verify_nat_gateways
                    fi
                    ;;
                "03")
                    # Retry SPIRE DB password retrieval (step 01 just ran)
                    retrieve_spire_db_password
                    ;;
                "05")
                    info "Running automated root CA generation and intermediate signing"
                    "$SCRIPT_DIR/pve-root-ca.sh" generate
                    ;;
                "08"|"09")
                    # Generate SPIRE join tokens before agent setup (step 08 or 09).
                    # Shared sequence has step 08; per-env sequences start at 09.
                    # SPIRE Server must be running (steps 03-07 complete in shared).
                    if [[ $tokens_generated -eq 0 ]]; then
                        generate_spire_join_tokens "${sequence[@]}"
                        tokens_generated=1
                    fi
                    if [[ "$step" == "09" && "$prev_step" == "08" ]]; then
                        verify_spire_agents
                    fi
                    ;;
            esac
        fi

        # Validate dependencies
        if ! validate_dependencies "$step"; then
            err "Prerequisites not met for step $step. Run earlier steps first or use --force."
        fi

        # Look up host record and resolve CTID
        local host_entry
        host_entry=$(lookup_host "$host") || err "Host $host not found in inventory"
        parse_host "$host_entry"

        if [[ -z "$H_CTID" ]]; then
            err "Could not resolve CTID for $host. Is the host running?"
        fi

        info "Step $step: $script on $host (CTID $H_CTID, $H_IP)"

        # Inject secrets into env_vars for spire-server scripts
        if [[ "$host" == "spire-server" && -n "${SPIRE_DB_PASSWORD:-}" ]]; then
            env_vars="${env_vars:+$env_vars }SPIRE_DB_PASSWORD=$SPIRE_DB_PASSWORD"
        fi

        # Execute (run without pipeline so set -e catches failures directly)
        local rc=0
        if [[ "$H_TYPE" == "lxc" ]]; then
            run_on_lxc "$H_CTID" "$script" "${env_vars:-}" > >(redact | tee -a "$LOG_FILE") 2>&1 || rc=$?
        elif [[ "$H_TYPE" == "vm" ]]; then
            run_on_vm "$H_IP" "$script" "${env_vars:-}" > >(redact | tee -a "$LOG_FILE") 2>&1 || rc=$?
        fi

        if [[ $rc -ne 0 ]]; then
            err "Step $step failed on $host (CTID $H_CTID, exit code $rc)"
        fi

        record_step "$step" "$host" "$script"
        prev_step="$step"
    done

    info "=== $label deployment complete ==="
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    info "WOL Deployment Orchestrator"
    info "Log: $LOG_FILE"

    # Retrieve SPIRE DB password from db host (needed by spire-server bootstrap scripts).
    # This runs after step 01 has created the db and written the password file.
    retrieve_spire_db_password

    # Determine which sequences to run
    if [[ -n "$FILTER_HOST" ]]; then
        # --host filter: search across all sequences
        run_sequence "all (filtered by host=$FILTER_HOST)" "${BOOTSTRAP_SEQUENCE[@]}"
    elif [[ $DEPLOY_ALL -eq 1 ]]; then
        run_sequence "shared infrastructure" "${BOOTSTRAP_SHARED[@]}"
        run_sequence "prod environment" "${BOOTSTRAP_PROD[@]}"
        run_sequence "test environment" "${BOOTSTRAP_TEST[@]}"
    elif [[ "$FILTER_ENV" == "prod" ]]; then
        run_sequence "prod environment" "${BOOTSTRAP_PROD[@]}"
    elif [[ "$FILTER_ENV" == "test" ]]; then
        run_sequence "test environment" "${BOOTSTRAP_TEST[@]}"
    elif [[ -n "$FILTER_ENV" ]]; then
        err "Unknown environment: $FILTER_ENV (expected: prod or test)"
    else
        run_sequence "shared infrastructure" "${BOOTSTRAP_SHARED[@]}"
    fi

    # Post-deploy secret scrub
    scrub_secrets

    info "Deployment complete. Log: $LOG_FILE"
}

main "$@"
