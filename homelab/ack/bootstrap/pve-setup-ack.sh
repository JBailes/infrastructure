#!/usr/bin/env bash
# pve-setup-ack.sh -- Create and bootstrap the ACK! MUD network
#
# Runs on: the Proxmox host
#
# Creates:
#   - vmbr2 bridge (10.1.0.0/24, ACK! isolated network)
#   - ack-gateway (CTID 240, dual-homed, NAT + port forwarding)
#   - ack-db (CTID 246, PostgreSQL database)
#   - 6 MUD servers (CTIDs 241-245, 250)
#   - ack-web (CTID 247, AHA web frontend)
#
# Usage:
#   ./pve-setup-ack.sh              # Full setup
#   ./pve-setup-ack.sh --skip-bridge  # Skip bridge creation (already exists)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo ""; echo "=================================================================="; echo "==> $*"; echo "=================================================================="; }
step() { echo ""; echo "--- $*"; }

[[ $EUID -eq 0 ]] || err "Run as root"

SKIP_BRIDGE=0
[[ "${1:-}" == "--skip-bridge" ]] && SKIP_BRIDGE=1

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

BRIDGE="vmbr2"
# Keep the Proxmox host bridge IP distinct from the ACK gateway container IP
# (gateway uses 10.1.0.240 on eth1). Using .254 avoids ARP/IP conflicts.
BRIDGE_IP="10.1.0.254/24"
STORAGE="${STORAGE:-fast}"
IMAGE_STORAGE="${IMAGE_STORAGE:-isos}"
TEMPLATE="${IMAGE_STORAGE}:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst"
SSH_KEY="/root/.ssh/id_ed25519.pub"

# Host definitions: name|ctid|ip|ext_ip|privileged|disk|ram|cores|description
HOSTS=(
    "ack-gateway|240|10.1.0.240|192.168.1.240|yes|4|256|1|ACK! gateway (NAT + port forwarding)"
    "acktng|241|10.1.0.241||no|8|512|1|ACK!TNG MUD server"
    "ack431|242|10.1.0.242||no|4|256|1|ACK! 4.3.1 MUD server"
    "ack42|243|10.1.0.243||no|4|256|1|ACK! 4.2 MUD server"
    "ack41|244|10.1.0.244||no|4|256|1|ACK! 4.1 MUD server"
    "assault30|245|10.1.0.245||no|4|256|1|Assault 3.0 MUD server"
    "ackfuss|250|10.1.0.250||no|4|256|1|ACK!FUSS 4.4.1 MUD server"
    "ack-db|246|10.1.0.246||no|32|1024|1|PostgreSQL database (acktng)"
    "ack-web|247|10.1.0.247||no|8|512|1|AHA web frontend (aha.ackmud.com)"
    "tng-ai|248|10.1.0.248||no|4|512|1|NPC dialogue AI (Python/FastAPI/Groq)"
    "tngdb|249|10.1.0.249||no|4|256|1|Read-only game content API (Python/FastAPI)"
)

# ---------------------------------------------------------------------------
# Phase 1: Create vmbr2 bridge
# ---------------------------------------------------------------------------

setup_bridge() {
    if [[ $SKIP_BRIDGE -eq 1 ]]; then
        info "Skipping bridge creation (--skip-bridge)"
        return
    fi

    if ip link show "$BRIDGE" &>/dev/null; then
        step "vmbr2 already exists, skipping"
        return
    fi

    info "Phase 1: Create ACK! network bridge (vmbr2)"

    if ! grep -q "iface $BRIDGE" /etc/network/interfaces 2>/dev/null; then
        cat >> /etc/network/interfaces <<BRIDGE_CONF

auto $BRIDGE
iface $BRIDGE inet static
    address $BRIDGE_IP
    bridge-ports none
    bridge-stp off
    bridge-fd 0
BRIDGE_CONF
        step "vmbr2 added to /etc/network/interfaces"
    fi

    ifreload -a
    step "Bridge vmbr2 is up (10.1.0.0/24)"
}

# ---------------------------------------------------------------------------
# Phase 2: Create containers
# ---------------------------------------------------------------------------

create_containers() {
    info "Phase 2: Create ACK! containers"

    for entry in "${HOSTS[@]}"; do
        IFS='|' read -r name ctid ip ext_ip priv disk ram cores desc <<< "$entry"

        if pct status "$ctid" &>/dev/null; then
            step "SKIP: CT $ctid ($name) already exists"
            continue
        fi

        local priv_flag="--unprivileged 1"
        [[ "$priv" == "yes" ]] && priv_flag="--unprivileged 0"

        local features="--features nesting=1"
        [[ "$priv" == "yes" ]] && features="--features nesting=1,keyctl=1"

        local net_args=""
        if [[ -n "$ext_ip" ]]; then
            # Dual-homed: eth0 = external (vmbr0), eth1 = internal (vmbr2)
            net_args="--net0 name=eth0,bridge=vmbr0,ip=${ext_ip}/24,gw=192.168.1.1"
            net_args+=" --net1 name=eth1,bridge=${BRIDGE},ip=${ip}/24"
        else
            # Single-homed: eth0 = internal (vmbr2)
            net_args="--net0 name=eth0,bridge=${BRIDGE},ip=${ip}/24,gw=10.1.0.240"
        fi

        step "Creating CT $ctid ($name) at $ip"
        # shellcheck disable=SC2086
        pct create "$ctid" "$TEMPLATE" \
            --hostname "$name" \
            --ostype debian \
            --storage "$STORAGE" \
            --rootfs "${STORAGE}:${disk}" \
            --memory "$ram" \
            --cores "$cores" \
            --ssh-public-keys "$SSH_KEY" \
            $features \
            $priv_flag \
            $net_args \
            --onboot 1

        # Generate locale
        pct start "$ctid" 2>/dev/null || true
        sleep 2
        pct exec "$ctid" -- bash -c "
            sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen 2>/dev/null
            locale-gen en_US.UTF-8 2>/dev/null
            update-locale LANG=en_US.UTF-8 2>/dev/null
        " 2>/dev/null || true
        pct stop "$ctid" 2>/dev/null || true
        sleep 1

        # Start with retry
        local attempt
        for attempt in 1 2 3 4 5; do
            sleep "$((attempt * 2))"
            if pct start "$ctid" 2>/dev/null; then
                break
            fi
            if [[ $attempt -lt 5 ]]; then
                echo "WARN: CT $ctid start attempt $attempt failed, retrying..."
            else
                err "CT $ctid ($name) failed to start after $attempt attempts"
            fi
        done

        step "CREATED: CT $ctid ($name) at $ip"
    done
}

# ---------------------------------------------------------------------------
# Phase 3: Bootstrap
# ---------------------------------------------------------------------------

bootstrap() {
    info "Phase 3: Bootstrap ACK! hosts"

    # Bootstrap gateway first
    step "Bootstrapping ack-gateway (CT 240)"
    pct push 240 "$SCRIPT_DIR/00-setup-ack-gateway.sh" /root/00-setup-ack-gateway.sh --perms 0755
    pct exec 240 -- bash -c "DEBIAN_FRONTEND=noninteractive TERM=dumb /root/00-setup-ack-gateway.sh"

    # Wait for gateway to be ready
    sleep 3

    # Bootstrap database (must be ready before MUD servers)
    step "Bootstrapping ack-db (CT 246)"
    pct push 246 "$SCRIPT_DIR/03-setup-ack-db.sh" /root/03-setup-ack-db.sh --perms 0755
    pct exec 246 -- bash -c "DEBIAN_FRONTEND=noninteractive TERM=dumb /root/03-setup-ack-db.sh --configure"

    # Bootstrap MUD servers: name|ctid|ip|port|repo
    local mud_hosts=(
        "acktng|241|10.1.0.241|4000|https://github.com/ackmudhistoricalarchive/acktng.git"
        "ack431|242|10.1.0.242|4000|https://github.com/ackmudhistoricalarchive/ackmud431.git"
        "ack42|243|10.1.0.243|4000|https://github.com/ackmudhistoricalarchive/ackmud42.git"
        "ack41|244|10.1.0.244|4000|https://github.com/ackmudhistoricalarchive/ackmud41.git"
        "assault30|245|10.1.0.245|4000|https://github.com/ackmudhistoricalarchive/Assault3.0.git"
        "ackfuss|250|10.1.0.250|4000|https://github.com/ackmudhistoricalarchive/ACKFUSS.git"
    )

    for entry in "${mud_hosts[@]}"; do
        IFS='|' read -r name ctid ip port repo <<< "$entry"
        step "Bootstrapping $name (CT $ctid)"
        pct push "$ctid" "$SCRIPT_DIR/01-setup-ack-mud.sh" /root/01-setup-ack-mud.sh --perms 0755
        local repo_env=""
        [[ -n "$repo" ]] && repo_env="MUD_REPO=$repo"
        pct exec "$ctid" -- bash -c "DEBIAN_FRONTEND=noninteractive TERM=dumb MUD_NAME=$name MUD_IP=$ip MUD_PORT=$port $repo_env /root/01-setup-ack-mud.sh"
    done

    # Bootstrap ack-web
    step "Bootstrapping ack-web (CT 247)"
    pct push 247 "$SCRIPT_DIR/04-setup-ack-web.sh" /root/04-setup-ack-web.sh --perms 0755
    pct exec 247 -- bash -c "DEBIAN_FRONTEND=noninteractive TERM=dumb /root/04-setup-ack-web.sh --configure"

    # Bootstrap tng-ai
    step "Bootstrapping tng-ai (CT 248)"
    pct push 248 "$SCRIPT_DIR/05-setup-tng-ai.sh" /root/05-setup-tng-ai.sh --perms 0755
    pct exec 248 -- bash -c "DEBIAN_FRONTEND=noninteractive TERM=dumb /root/05-setup-tng-ai.sh --configure"

    # Bootstrap tngdb
    step "Bootstrapping tngdb (CT 249)"
    pct push 249 "$SCRIPT_DIR/06-setup-tngdb.sh" /root/06-setup-tngdb.sh --perms 0755
    pct exec 249 -- bash -c "DEBIAN_FRONTEND=noninteractive TERM=dumb /root/06-setup-tngdb.sh --configure"
}

# ---------------------------------------------------------------------------
# Phase 3b: Migrate data from legacy containers
# ---------------------------------------------------------------------------

migrate_data() {
    info "Phase 3b: Migrate data from legacy containers"

    # -------------------------------------------------------------------------
    # Database migration: CT 112 (old tngdb host) -> CT 246 (ack-db)
    # pg_dump the acktng database from the old host, pg_restore into ack-db.
    # -------------------------------------------------------------------------
    if pct status 112 &>/dev/null && pct status 246 &>/dev/null; then
        step "Migrating acktng database (CT 112 -> CT 246)"

        local dump_file="/tmp/acktng-migration.sql"

        # Dump from old host (CT 112 runs PostgreSQL with peer auth for postgres)
        pct exec 112 -- sudo -u postgres pg_dump --clean --if-exists acktng > "$dump_file" 2>/dev/null

        local dump_size
        dump_size=$(wc -c < "$dump_file")
        if [[ "$dump_size" -lt 100 ]]; then
            echo "WARN: pg_dump produced empty or very small output ($dump_size bytes), skipping restore" >&2
        else
            step "Database dump: $dump_size bytes"

            # Push dump to ack-db and restore
            pct push 246 "$dump_file" /tmp/acktng-migration.sql
            pct exec 246 -- sudo -u postgres psql -d acktng -f /tmp/acktng-migration.sql 2>&1 | tail -5
            pct exec 246 -- rm -f /tmp/acktng-migration.sql

            # Verify schema_version
            local version
            version=$(pct exec 246 -- sudo -u postgres psql -d acktng -t -c "SELECT MAX(version) FROM schema_version" 2>/dev/null | tr -d ' ')
            step "Database restored (schema_version: $version)"
        fi

        rm -f "$dump_file"
    else
        step "SKIP: CT 112 or CT 246 not available, skipping database migration"
    fi

    # -------------------------------------------------------------------------
    # tng-ai credentials: copy GROQ_API_KEY from CT 111 -> CT 248
    # -------------------------------------------------------------------------
    if pct status 111 &>/dev/null && pct status 248 &>/dev/null; then
        step "Migrating tng-ai credentials (CT 111 -> CT 248)"

        local groq_key
        groq_key=$(pct exec 111 -- bash -c 'grep -oP "GROQ_API_KEY=\K.*" /root/.env 2>/dev/null || grep -oP "GROQ_API_KEY=\K.*" /opt/tng-ai/.env 2>/dev/null || echo ""' 2>/dev/null)

        if [[ -n "$groq_key" && "$groq_key" != "REPLACE_ME" ]]; then
            pct exec 248 -- bash -c "sed -i 's/^GROQ_API_KEY=.*/GROQ_API_KEY=$groq_key/' /etc/tng-ai/env"
            step "GROQ_API_KEY set on CT 248"
        else
            echo "WARN: could not find GROQ_API_KEY on CT 111, set it manually in /etc/tng-ai/env on CT 248" >&2
        fi
    else
        step "SKIP: CT 111 or CT 248 not available, skipping tng-ai credential migration"
    fi

    # -------------------------------------------------------------------------
    # tngdb credentials: read ack_readonly password from ack-db, set on tngdb
    # -------------------------------------------------------------------------
    if pct status 246 &>/dev/null && pct status 249 &>/dev/null; then
        step "Configuring tngdb database credentials (CT 246 -> CT 249)"

        local db_pass
        db_pass=$(pct exec 246 -- cat /etc/ack-db-secrets/ack_readonly_password 2>/dev/null)

        if [[ -n "$db_pass" ]]; then
            pct exec 249 -- bash -c "sed -i 's|DATABASE_URL=.*|DATABASE_URL=postgres://ack_readonly:${db_pass}@10.1.0.246/acktng|' /etc/tngdb/env"
            step "DATABASE_URL configured on CT 249"
        else
            echo "WARN: could not read ack_readonly password from CT 246, set DATABASE_URL manually on CT 249" >&2
        fi
    else
        step "SKIP: CT 246 or CT 249 not available, skipping tngdb credential setup"
    fi

    # -------------------------------------------------------------------------
    # ack431 player files: CT 101 (old) -> CT 242 (new)
    # -------------------------------------------------------------------------
    if pct status 101 &>/dev/null && pct status 242 &>/dev/null; then
        step "Migrating ack431 player files (CT 101 -> CT 242)"

        local tmp_dir="/tmp/ack431-player-migration"
        rm -rf "$tmp_dir"
        mkdir -p "$tmp_dir"

        # Pull player directory from old container
        pct pull 101 /root/ackmud431/player "$tmp_dir/player" 2>/dev/null || true

        # Count files to migrate
        local count
        count=$(find "$tmp_dir/player" -type f 2>/dev/null | wc -l)

        if [[ "$count" -gt 0 ]]; then
            # Push to new container
            pct push 242 "$tmp_dir/player" /opt/mud/src/player --perms 0644
            step "Migrated $count player file(s) to CT 242"
        else
            step "No player files found on CT 101, skipping"
        fi

        rm -rf "$tmp_dir"
    else
        step "SKIP: CT 101 or CT 242 not available, skipping ack431 player migration"
    fi
}

# ---------------------------------------------------------------------------
# Phase 4: Deploy Promtail to all ACK hosts
# ---------------------------------------------------------------------------

deploy_promtail() {
    local promtail_script="$SCRIPT_DIR/02-setup-promtail.sh"

    if [[ ! -f "$promtail_script" ]]; then
        echo "WARN: $promtail_script not found, skipping Promtail deployment" >&2
        return
    fi

    # Check if obs is reachable on the ACK network
    if ! curl -sf -k --connect-timeout 3 "https://10.1.0.100:3100/ready" &>/dev/null; then
        echo "WARN: obs not reachable at 10.1.0.100:3100, skipping Promtail deployment" >&2
        echo "      Run Promtail deployment later: deploy 02-setup-promtail.sh to each ACK host" >&2
        return
    fi

    info "Phase 4: Deploy Promtail to ACK hosts"

    for entry in "${HOSTS[@]}"; do
        IFS='|' read -r name ctid _ _ _ _ _ _ _ <<< "$entry"
        if pct status "$ctid" &>/dev/null; then
            step "Deploying Promtail to $name (CT $ctid)"
            pct push "$ctid" "$promtail_script" /root/02-setup-promtail.sh --perms 0755
            pct exec "$ctid" -- bash -c "DEBIAN_FRONTEND=noninteractive TERM=dumb /root/02-setup-promtail.sh --configure"
        fi
    done
}

# ---------------------------------------------------------------------------
# Phase 5: Start all services
# ---------------------------------------------------------------------------

start_services() {
    info "Phase 5: Start all services"

    # MUD servers
    local mud_ctids=(241 242 243 244 245 250)
    for ctid in "${mud_ctids[@]}"; do
        local name
        name=$(pct exec "$ctid" -- hostname 2>/dev/null || echo "CT $ctid")
        if pct exec "$ctid" -- systemctl is-enabled mud.service &>/dev/null; then
            step "Starting mud.service on $name (CT $ctid)"
            pct exec "$ctid" -- systemctl start mud.service 2>&1 || echo "WARN: mud.service failed to start on CT $ctid"
        else
            step "SKIP: mud.service not enabled on CT $ctid"
        fi
    done

    # tng-ai
    if pct status 248 &>/dev/null; then
        local key
        key=$(pct exec 248 -- bash -c 'grep -oP "GROQ_API_KEY=\K.*" /etc/tng-ai/env 2>/dev/null' 2>/dev/null)
        if [[ -n "$key" && "$key" != "REPLACE_ME" ]]; then
            step "Starting tng-ai.service (CT 248)"
            pct exec 248 -- systemctl start tng-ai.service 2>&1 || echo "WARN: tng-ai.service failed to start"
        else
            step "SKIP: tng-ai GROQ_API_KEY not set, not starting service"
        fi
    fi

    # tngdb
    if pct status 249 &>/dev/null; then
        local db_url
        db_url=$(pct exec 249 -- bash -c 'grep -oP "DATABASE_URL=\K.*" /etc/tngdb/env 2>/dev/null' 2>/dev/null)
        if [[ -n "$db_url" && "$db_url" != *"REPLACE_ME"* ]]; then
            step "Starting tngdb.service (CT 249)"
            pct exec 249 -- systemctl start tngdb.service 2>&1 || echo "WARN: tngdb.service failed to start"
        else
            step "SKIP: tngdb DATABASE_URL not configured, not starting service"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Phase 6: Verify services
# ---------------------------------------------------------------------------

verify_services() {
    info "Phase 6: Verify services"

    local all_ok=1

    # MUD servers: check TCP on :4000
    local mud_hosts=("acktng|241|10.1.0.241" "ack431|242|10.1.0.242" "ack42|243|10.1.0.243" "ack41|244|10.1.0.244" "assault30|245|10.1.0.245" "ackfuss|250|10.1.0.250")
    for entry in "${mud_hosts[@]}"; do
        IFS='|' read -r name ctid ip <<< "$entry"
        if timeout 3 bash -c "echo >/dev/tcp/$ip/4000" 2>/dev/null; then
            step "OK: $name (CT $ctid) listening on :4000"
        else
            step "FAIL: $name (CT $ctid) not responding on :4000"
            all_ok=0
        fi
    done

    # tng-ai: check HTTP health
    if curl -sf --connect-timeout 3 "http://10.1.0.248:8000/health" &>/dev/null; then
        step "OK: tng-ai (CT 248) health check passed"
    else
        step "FAIL: tng-ai (CT 248) health check failed"
        all_ok=0
    fi

    # tngdb: check HTTP health
    if curl -sf --connect-timeout 3 "http://10.1.0.249:8000/health" &>/dev/null; then
        step "OK: tngdb (CT 249) health check passed"
    else
        step "FAIL: tngdb (CT 249) health check failed"
        all_ok=0
    fi

    # ack-web: check HTTP health
    if curl -sf --connect-timeout 3 "http://10.1.0.247:5000/health" &>/dev/null; then
        step "OK: ack-web (CT 247) health check passed"
    else
        step "FAIL: ack-web (CT 247) health check failed"
        all_ok=0
    fi

    # ack-db: check PostgreSQL
    if pct exec 246 -- sudo -u postgres psql -d acktng -c "SELECT 1" &>/dev/null; then
        step "OK: ack-db (CT 246) PostgreSQL responding"
    else
        step "FAIL: ack-db (CT 246) PostgreSQL not responding"
        all_ok=0
    fi

    if [[ "$all_ok" -eq 1 ]]; then
        step "All services verified"
    else
        echo ""
        echo "WARN: some services failed verification, check logs above" >&2
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    echo ""
    echo "  ACK! MUD Network Setup"
    echo ""

    setup_bridge
    create_containers
    bootstrap
    migrate_data
    deploy_promtail
    start_services
    verify_services

    info "ACK! MUD network setup complete"
    echo ""
    echo "  Gateway:  192.168.1.240 (external), 10.1.0.240 (internal)"
    echo "  Bridge:   vmbr2 (10.1.0.0/24)"
    echo "  apt-cache: 10.1.0.115 (tri-homed, managed by homelab/bootstrap/00-setup-apt-cache.sh)"
    echo ""
    echo "  Database:"
    echo "    ack-db    -> 10.1.0.246:5432 (PostgreSQL, acktng database)"
    echo ""
    echo "  Game servers:"
    echo "    acktng    -> 192.168.1.240:8890 (10.1.0.241:4000)"
    echo "    ack431    -> 192.168.1.240:8891 (10.1.0.242:4000)"
    echo "    ack42     -> 192.168.1.240:8892 (10.1.0.243:4000)"
    echo "    ack41     -> 192.168.1.240:8893 (10.1.0.244:4000)"
    echo "    assault30 -> 192.168.1.240:8894 (10.1.0.245:4000)"
    echo "    ackfuss   -> 192.168.1.240:8895 (10.1.0.250:4000)"
    echo ""
    echo "  Web:"
    echo "    ack-web   -> 10.1.0.247:5000 (aha.ackmud.com, proxied by nginx-proxy)"
    echo ""
    echo "  Services:"
    echo "    tng-ai    -> 10.1.0.248:8000 (NPC dialogue AI)"
    echo "    tngdb     -> 10.1.0.249:8000 (read-only game content API)"
    echo ""
}

main "$@"
