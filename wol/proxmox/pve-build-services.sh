#!/usr/bin/env bash
# pve-build-services.sh -- Build .NET services on the Proxmox host and deploy to containers
#
# Runs on: the Proxmox host (not inside containers)
#
# This script clones (or pulls) service repos on the Proxmox host, builds them
# with dotnet publish, and pushes the published artifacts to the target LXC
# containers via pct push. This avoids the need for SSH keys or the .NET SDK
# inside containers (they only need the ASP.NET Core runtime).
#
# Prerequisites:
#   - .NET 9 SDK installed on the Proxmox host
#   - SSH key configured for GitHub (git@github.com:JBailes/...)
#   - Target containers must be running
#   - Host setup scripts (bootstrap) should have run first to create users,
#     directories, systemd units, etc.
#
# Usage:
#   ./pve-build-services.sh                     # Build and deploy all services
#   ./pve-build-services.sh --service wol-accounts  # Build and deploy one service
#   ./pve-build-services.sh --env prod           # Build and deploy prod services only
#   ./pve-build-services.sh --env test           # Build and deploy test services only
#   ./pve-build-services.sh --list               # List all configured services

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

BUILD_ROOT="/opt/wol-builds"
PUBLISH_ROOT="/tmp/wol-publish"

# ---------------------------------------------------------------------------
# Service definitions
#
# Each entry: name|repo_ssh_url|project_path|dest_dir|owner|service_unit|hosts
#
# hosts is a space-separated list of container hostnames to deploy to.
# The CTID is resolved from inventory at runtime.
# ---------------------------------------------------------------------------

SERVICES=(
    "wol-accounts|git@github.com:JBailes/wol-accounts.git|Wol.Accounts/Wol.Accounts.csproj|/usr/lib/wol-accounts|wol-accounts:wol-accounts|wol-accounts|wol-accounts"
    "wol-world|git@github.com:JBailes/wol-world.git|src/Wol.World/Wol.World.csproj|/usr/lib/wol-world|wol-world:wol-world|wol-world|wol-world-prod wol-world-test"
    "wol-realm|git@github.com:JBailes/wol-realm.git|Wol.Realm/Wol.Realm.csproj|/usr/lib/wol-realm/app|wol-realm:wol-realm|wol-realm|wol-realm-prod wol-realm-test"
    "wol|git@github.com:JBailes/wol.git|Wol.Server/Wol.Server.csproj|/usr/lib/wol/app|wol:wol|wol|wol-a"
    "wol-ai|git@github.com:JBailes/wol-ai.git|src/Wol.Ai/Wol.Ai.csproj|/usr/lib/wol-ai|wol-ai:wol-ai|wol-ai|wol-ai-prod wol-ai-test"
    "wol-web|git@github.com:JBailes/web-wol.git|WolWeb.Host/WolWeb.Host.csproj|/opt/wol-web/publish|wol-web:wol-web|wolweb|wol-web"
)

# ---------------------------------------------------------------------------
# Parse a service definition
# ---------------------------------------------------------------------------

parse_service() {
    local record="$1"
    IFS='|' read -r SVC_NAME SVC_REPO SVC_PROJECT SVC_DEST SVC_OWNER SVC_UNIT SVC_HOSTS <<< "$record"
}

# ---------------------------------------------------------------------------
# Clone or pull a repo
# ---------------------------------------------------------------------------

clone_or_pull() {
    local name="$1" repo="$2"
    local clone_dir="$BUILD_ROOT/$name"

    if [[ -d "$clone_dir/.git" ]]; then
        info "[$name] Pulling latest from $repo"
        cd "$clone_dir"
        git fetch origin
        git reset --hard origin/main
    else
        info "[$name] Cloning $repo"
        mkdir -p "$BUILD_ROOT"
        git clone "$repo" "$clone_dir"
    fi
}

# ---------------------------------------------------------------------------
# Build (dotnet publish)
# ---------------------------------------------------------------------------

build_service() {
    local name="$1" project="$2"
    local clone_dir="$BUILD_ROOT/$name"
    local publish_dir="$PUBLISH_ROOT/$name"

    info "[$name] Building: dotnet publish $project"
    rm -rf "$publish_dir"
    mkdir -p "$publish_dir"

    cd "$clone_dir"
    dotnet publish "$project" \
        --configuration Release \
        --output "$publish_dir"

    info "[$name] Build complete: $publish_dir"
}

# ---------------------------------------------------------------------------
# Deploy to a container (pct push for LXC, scp for VM)
# ---------------------------------------------------------------------------

deploy_to_host() {
    local name="$1" target_host="$2" dest_dir="$3" owner="$4" service_unit="$5"
    local publish_dir="$PUBLISH_ROOT/$name"

    local host_entry
    host_entry=$(lookup_host "$target_host") || err "Host $target_host not found in inventory"
    parse_host "$host_entry"

    local ctid="$H_CTID"
    local host_type="$H_TYPE"
    local host_ip="$H_IP"

    if [[ -z "$ctid" ]]; then
        err "Could not resolve CTID for $target_host"
    fi

    info "[$name] Deploying to $target_host (CTID $ctid, $host_type)"

    # Ensure destination directory exists
    if [[ "$host_type" == "lxc" ]]; then
        pct exec "$ctid" -- mkdir -p "$dest_dir"
    elif [[ "$host_type" == "vm" ]]; then
        ssh -o StrictHostKeyChecking=accept-new "root@${host_ip}" "mkdir -p $dest_dir"
    fi

    # Push all files from the publish directory
    local file_count=0
    while IFS= read -r -d '' file; do
        local rel_path="${file#$publish_dir/}"
        local target_path="$dest_dir/$rel_path"
        local target_dir
        target_dir=$(dirname "$target_path")

        if [[ "$host_type" == "lxc" ]]; then
            pct exec "$ctid" -- mkdir -p "$target_dir"
            pct push "$ctid" "$file" "$target_path" --perms 0755
        elif [[ "$host_type" == "vm" ]]; then
            ssh -o StrictHostKeyChecking=accept-new "root@${host_ip}" "mkdir -p $target_dir"
            scp -o StrictHostKeyChecking=accept-new "$file" "root@${host_ip}:${target_path}"
        fi
        file_count=$((file_count + 1))
    done < <(find "$publish_dir" -type f -print0)

    info "[$name] Pushed $file_count files to $target_host:$dest_dir"

    # Set ownership
    local owner_user owner_group
    IFS=':' read -r owner_user owner_group <<< "$owner"
    if [[ "$host_type" == "lxc" ]]; then
        pct exec "$ctid" -- chown -R "${owner_user}:${owner_group}" "$dest_dir"
    elif [[ "$host_type" == "vm" ]]; then
        ssh -o StrictHostKeyChecking=accept-new "root@${host_ip}" "chown -R ${owner_user}:${owner_group} $dest_dir"
    fi

    # Restart the service (if the unit exists)
    info "[$name] Restarting $service_unit on $target_host"
    if [[ "$host_type" == "lxc" ]]; then
        pct exec "$ctid" -- systemctl restart "$service_unit" 2>/dev/null || \
            warn "[$name] Could not restart $service_unit on $target_host (unit may not be installed yet)"
    elif [[ "$host_type" == "vm" ]]; then
        ssh -o StrictHostKeyChecking=accept-new "root@${host_ip}" \
            "systemctl restart $service_unit" 2>/dev/null || \
            warn "[$name] Could not restart $service_unit on $target_host (unit may not be installed yet)"
    fi
}

# ---------------------------------------------------------------------------
# Build and deploy a single service to all its target hosts
# ---------------------------------------------------------------------------

build_and_deploy() {
    local record="$1"
    parse_service "$record"

    clone_or_pull "$SVC_NAME" "$SVC_REPO"
    build_service "$SVC_NAME" "$SVC_PROJECT"

    for target_host in $SVC_HOSTS; do
        deploy_to_host "$SVC_NAME" "$target_host" "$SVC_DEST" "$SVC_OWNER" "$SVC_UNIT"
    done

    info "[$SVC_NAME] Done"
}

# ---------------------------------------------------------------------------
# Filter helpers
# ---------------------------------------------------------------------------

# Check if a service's hosts include any host matching the given environment.
# "prod" matches hosts ending in -prod or shared hosts (no -prod/-test suffix).
# "test" matches hosts ending in -test or shared hosts.
service_matches_env() {
    local hosts="$1" env="$2"
    for host in $hosts; do
        case "$env" in
            prod)
                if [[ "$host" == *-prod ]] || { [[ "$host" != *-test ]] && [[ "$host" != *-prod ]]; }; then
                    return 0
                fi
                ;;
            test)
                if [[ "$host" == *-test ]] || { [[ "$host" != *-test ]] && [[ "$host" != *-prod ]]; }; then
                    return 0
                fi
                ;;
        esac
    done
    return 1
}

# Filter target hosts by environment
filter_hosts_by_env() {
    local hosts="$1" env="$2"
    local filtered=""
    for host in $hosts; do
        case "$env" in
            prod)
                if [[ "$host" == *-prod ]] || { [[ "$host" != *-test ]] && [[ "$host" != *-prod ]]; }; then
                    filtered="${filtered:+$filtered }$host"
                fi
                ;;
            test)
                if [[ "$host" == *-test ]] || { [[ "$host" != *-test ]] && [[ "$host" != *-prod ]]; }; then
                    filtered="${filtered:+$filtered }$host"
                fi
                ;;
        esac
    done
    echo "$filtered"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

FILTER_SERVICE=""
FILTER_ENV=""
LIST_ONLY=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --service) FILTER_SERVICE="$2"; shift 2 ;;
        --env)     FILTER_ENV="$2"; shift 2 ;;
        --list)    LIST_ONLY=1; shift ;;
        *)         err "Unknown argument: $1" ;;
    esac
done

if [[ $LIST_ONLY -eq 1 ]]; then
    echo "Configured services:"
    for entry in "${SERVICES[@]}"; do
        parse_service "$entry"
        echo "  $SVC_NAME -> $SVC_HOSTS (unit: $SVC_UNIT)"
    done
    exit 0
fi

# Verify dotnet SDK is available
if ! command -v dotnet &>/dev/null; then
    err "dotnet CLI not found. Install the .NET 9 SDK on the Proxmox host first."
fi

info "WOL Service Builder"
info "Build root: $BUILD_ROOT"
info "Publish root: $PUBLISH_ROOT"

for entry in "${SERVICES[@]}"; do
    parse_service "$entry"

    # Apply service filter
    if [[ -n "$FILTER_SERVICE" && "$SVC_NAME" != "$FILTER_SERVICE" ]]; then
        continue
    fi

    # Apply environment filter
    if [[ -n "$FILTER_ENV" ]]; then
        if ! service_matches_env "$SVC_HOSTS" "$FILTER_ENV"; then
            continue
        fi
        # Narrow the host list to only matching hosts
        local_hosts=$(filter_hosts_by_env "$SVC_HOSTS" "$FILTER_ENV")
        entry="${SVC_NAME}|${SVC_REPO}|${SVC_PROJECT}|${SVC_DEST}|${SVC_OWNER}|${SVC_UNIT}|${local_hosts}"
    fi

    build_and_deploy "$entry"
done

# Clean up build artifacts
info "Cleaning up build artifacts"
rm -rf "$PUBLISH_ROOT"
rm -rf "$BUILD_ROOT"
info "All services built and deployed."
