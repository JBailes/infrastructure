#!/usr/bin/env bash
# 12-setup-media-stack.sh -- Create and configure the media automation stack LXC
#
# Runs on: the Proxmox host (creates CT 119, then configures it)
# Run order: Step 12 (after bittorrent, vpn-gateway)
#
# Usage:
#   ./12-setup-media-stack.sh               # Create CT and configure
#   ./12-setup-media-stack.sh --deploy-only  # Re-run configuration on existing CT
#   ./12-setup-media-stack.sh --configure    # (internal) Run inside the container
#
# Creates a privileged Debian 13 LXC (CT 119):
#   eth0 = 192.168.1.119/23 on vmbr0 (LAN, gateway = VPN gateway 192.168.1.104)
#
# Prerequisites:
#   - VPN gateway (192.168.1.104) must be running
#   - BitTorrent LXC (192.168.1.116) must be running with qBittorrent WebUI on :8080
#   - NAS NFS export 192.168.1.254:/mnt/data/storage must be accessible
#
# Deploys via Docker Compose:
#   - Prowlarr   (indexer manager)    :9696
#   - Sonarr     (TV)                 :8989
#   - Radarr     (movies)             :7878
#   - Lidarr     (music)              :8686
#   - Readarr    (books/audiobooks)   :8787
#
# All services connect to qBittorrent at 192.168.1.116:8080 with per-app
# download categories. NFS mount to NAS provides a single filesystem for
# downloads + media libraries, enabling hardlinks.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ===================================================================
# In-container configuration (runs inside CT 119)
# ===================================================================

configure() {
    VPN_GATEWAY="192.168.1.104"
    NAS_EXPORT="192.168.1.254:/mnt/data/storage"
    MOUNT_POINT="/mnt/storage"
    LAN_IFACE="eth0"
    APT_CACHE="192.168.1.115"
    APT_CACHE_PORT="3142"
    QBIT_HOST="192.168.1.116"
    QBIT_PORT="8080"
    MEDIA_UID=1000
    MEDIA_GID=1000
    COMPOSE_DIR="/opt/media-stack"

    err()  { echo "ERROR: $*" >&2; exit 1; }
    info() { echo "==> $*"; }

    [[ $EUID -eq 0 ]] || err "Run as root"

    LOCAL_IP=$(ip -4 addr show "$LAN_IFACE" | awk '/inet / {sub(/\/.*/, "", $2); print $2; exit}')

    # -- apt proxy
    configure_apt_proxy() {
        info "Configuring apt proxy (apt-cache at ${APT_CACHE}:${APT_CACHE_PORT})"
        cat > /etc/apt/apt.conf.d/01proxy <<APTPROXY
Acquire::http::Proxy "http://${APT_CACHE}:${APT_CACHE_PORT}";
Acquire::https::Proxy "http://${APT_CACHE}:${APT_CACHE_PORT}";
Acquire::http::Proxy::Fallback "DIRECT";
Acquire::https::Proxy::Fallback "DIRECT";
APTPROXY
    }

    # -- Docker
    install_docker() {
        if command -v docker &>/dev/null; then
            info "Docker already installed"
            return
        fi
        info "Installing Docker"
        apt-get update -qq
        apt-get install -y --no-install-recommends ca-certificates curl gnupg nfs-common

        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/debian/gpg \
            | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg

        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
            > /etc/apt/sources.list.d/docker.list

        apt-get update -qq
        apt-get install -y --no-install-recommends \
            docker-ce docker-ce-cli containerd.io docker-compose-plugin
        info "Docker installed"
    }

    # -- Media user
    setup_media_user() {
        if id media &>/dev/null; then
            info "Media user already exists"
            return
        fi
        info "Creating media user (uid=${MEDIA_UID}, gid=${MEDIA_GID})"
        groupadd -g "$MEDIA_GID" media
        useradd -u "$MEDIA_UID" -g "$MEDIA_GID" -r -s /usr/sbin/nologin -d /nonexistent media
    }

    # -- NFS mount
    setup_nfs_mount() {
        info "Configuring NFS mount to NAS"
        mkdir -p "$MOUNT_POINT"

        if ! grep -q "$NAS_EXPORT" /etc/fstab; then
            cat >> /etc/fstab <<FSTAB
$NAS_EXPORT $MOUNT_POINT nfs defaults,_netdev,nofail 0 0
FSTAB
        fi

        mount -a

        if mountpoint -q "$MOUNT_POINT"; then
            info "NAS mounted at $MOUNT_POINT"
        else
            err "Failed to mount $NAS_EXPORT at $MOUNT_POINT"
        fi

        # Ensure category download directories exist for qBittorrent
        mkdir -p "$MOUNT_POINT/bittorrent/complete/sonarr"
        mkdir -p "$MOUNT_POINT/bittorrent/complete/sonarr-anime"
        mkdir -p "$MOUNT_POINT/bittorrent/complete/radarr"
        mkdir -p "$MOUNT_POINT/bittorrent/complete/lidarr"
        mkdir -p "$MOUNT_POINT/bittorrent/complete/readarr"

        # Ensure media library directories exist
        mkdir -p "$MOUNT_POINT/video/TV Shows"
        mkdir -p "$MOUNT_POINT/video/Movies"
        mkdir -p "$MOUNT_POINT/video/Anime"
        mkdir -p "$MOUNT_POINT/music"
        mkdir -p "$MOUNT_POINT/books"

        info "Download category and library directories ready"
    }

    # -- Docker Compose
    write_compose() {
        info "Writing docker-compose.yml"
        mkdir -p "$COMPOSE_DIR"

        cat > "$COMPOSE_DIR/.env" <<ENV
# Media stack environment
PUID=${MEDIA_UID}
PGID=${MEDIA_GID}
TZ=America/Chicago
STORAGE=${MOUNT_POINT}
ENV

        cat > "$COMPOSE_DIR/docker-compose.yml" <<'COMPOSE'
services:
  prowlarr:
    image: lscr.io/linuxserver/prowlarr:latest
    container_name: prowlarr
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
    volumes:
      - prowlarr-config:/config
    ports:
      - "9696:9696"
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:9696/ping"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s

  sonarr:
    image: lscr.io/linuxserver/sonarr:latest
    container_name: sonarr
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
    volumes:
      - sonarr-config:/config
      - ${STORAGE}:/mnt/storage
    ports:
      - "8989:8989"
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8989/ping"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s

  sonarr-anime:
    image: lscr.io/linuxserver/sonarr:latest
    container_name: sonarr-anime
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
    volumes:
      - sonarr-anime-config:/config
      - ${STORAGE}:/mnt/storage
    ports:
      - "8990:8989"
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8989/ping"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s

  radarr:
    image: lscr.io/linuxserver/radarr:latest
    container_name: radarr
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
    volumes:
      - radarr-config:/config
      - ${STORAGE}:/mnt/storage
    ports:
      - "7878:7878"
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:7878/ping"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s

  lidarr:
    image: lscr.io/linuxserver/lidarr:latest
    container_name: lidarr
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
    volumes:
      - lidarr-config:/config
      - ${STORAGE}:/mnt/storage
    ports:
      - "8686:8686"
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8686/ping"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s

  readarr:
    image: lscr.io/linuxserver/readarr:0.4.10-develop
    container_name: readarr
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
    volumes:
      - readarr-config:/config
      - ${STORAGE}:/mnt/storage
    ports:
      - "8787:8787"
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8787/ping"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s

volumes:
  prowlarr-config:
  sonarr-config:
  sonarr-anime-config:
  radarr-config:
  lidarr-config:
  readarr-config:
COMPOSE

        info "docker-compose.yml written to $COMPOSE_DIR"
    }

    # -- qBittorrent categories
    setup_qbittorrent_categories() {
        info "Configuring qBittorrent download categories"

        local qbit_url="http://${QBIT_HOST}:${QBIT_PORT}"
        local max_wait=30
        local elapsed=0

        while [[ $elapsed -lt $max_wait ]]; do
            if curl -sf "${qbit_url}/api/v2/app/version" &>/dev/null; then
                break
            fi
            sleep 2
            elapsed=$((elapsed + 2))
        done

        if ! curl -sf "${qbit_url}/api/v2/app/version" &>/dev/null; then
            info "WARN: qBittorrent API not reachable at ${qbit_url}, skipping category setup"
            info "      Configure categories manually after qBittorrent is accessible"
            return
        fi

        # Create categories with save paths relative to the default save path
        for cat in sonarr sonarr-anime radarr lidarr readarr; do
            curl -sf -X POST "${qbit_url}/api/v2/torrents/createCategory" \
                --data-urlencode "category=${cat}" \
                --data-urlencode "savePath=/mnt/torrents/complete/${cat}" \
                2>/dev/null || true
            info "  Category '${cat}' configured"
        done

        info "qBittorrent categories configured"
    }

    # -- Start services
    start_services() {
        info "Pulling and starting media stack"
        cd "$COMPOSE_DIR"
        docker compose pull
        docker compose up -d

        # Wait for health checks
        info "Waiting for services to become healthy..."
        sleep 15

        local all_ok=true
        for svc in prowlarr sonarr sonarr-anime radarr lidarr readarr; do
            local state
            state=$(docker inspect --format='{{.State.Health.Status}}' "$svc" 2>/dev/null || echo "unknown")
            if [[ "$state" == "healthy" ]]; then
                info "  ${svc}: healthy"
            else
                info "  ${svc}: ${state} (may still be starting)"
                all_ok=false
            fi
        done

        if [[ "$all_ok" == "true" ]]; then
            info "All services healthy"
        else
            info "Some services still starting. Check: docker compose -f ${COMPOSE_DIR}/docker-compose.yml ps"
        fi
    }

    # -- Prowlarr: register *arr applications for indexer sync
    configure_prowlarr_sync() {
        info "Configuring Prowlarr application sync"

        local prowlarr_url="http://localhost:9696"
        local max_wait=60
        local elapsed=0

        # Wait for Prowlarr API
        while [[ $elapsed -lt $max_wait ]]; do
            if curl -sf "${prowlarr_url}/ping" &>/dev/null; then
                break
            fi
            sleep 2
            elapsed=$((elapsed + 2))
        done

        if ! curl -sf "${prowlarr_url}/ping" &>/dev/null; then
            info "WARN: Prowlarr not responding at ${prowlarr_url}, skipping sync config"
            info "      Configure Prowlarr applications manually"
            return
        fi

        # Extract API keys from each service's config.xml
        local prowlarr_key sonarr_key sonarr_anime_key radarr_key lidarr_key readarr_key
        prowlarr_key=$(docker exec prowlarr cat /config/config.xml | sed -n 's/.*<ApiKey>\(.*\)<\/ApiKey>.*/\1/p')
        sonarr_key=$(docker exec sonarr cat /config/config.xml | sed -n 's/.*<ApiKey>\(.*\)<\/ApiKey>.*/\1/p')
        sonarr_anime_key=$(docker exec sonarr-anime cat /config/config.xml | sed -n 's/.*<ApiKey>\(.*\)<\/ApiKey>.*/\1/p')
        radarr_key=$(docker exec radarr cat /config/config.xml | sed -n 's/.*<ApiKey>\(.*\)<\/ApiKey>.*/\1/p')
        lidarr_key=$(docker exec lidarr cat /config/config.xml | sed -n 's/.*<ApiKey>\(.*\)<\/ApiKey>.*/\1/p')
        readarr_key=$(docker exec readarr cat /config/config.xml | sed -n 's/.*<ApiKey>\(.*\)<\/ApiKey>.*/\1/p')

        if [[ -z "$prowlarr_key" ]]; then
            info "WARN: Could not read Prowlarr API key, skipping sync config"
            return
        fi

        local api="${prowlarr_url}/api/v1/applications"
        local auth="X-Api-Key: ${prowlarr_key}"

        # Check if applications are already configured
        local existing
        existing=$(curl -s -H "$auth" "$api" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
        if [[ "$existing" -gt 0 ]]; then
            info "Prowlarr already has ${existing} application(s) configured, skipping"
            return
        fi

        # Helper: add an application to Prowlarr
        add_prowlarr_app() {
            local name="$1" impl="$2" contract="$3" base_url="$4" app_key="$5" cats="$6" extra="${7:-}"

            local fields="[
                {\"name\": \"prowlarrUrl\", \"value\": \"http://prowlarr:9696\"},
                {\"name\": \"baseUrl\", \"value\": \"${base_url}\"},
                {\"name\": \"apiKey\", \"value\": \"${app_key}\"},
                {\"name\": \"syncCategories\", \"value\": ${cats}}
                ${extra}
            ]"

            local payload="{
                \"syncLevel\": \"fullSync\",
                \"name\": \"${name}\",
                \"implementation\": \"${impl}\",
                \"configContract\": \"${contract}\",
                \"fields\": ${fields}
            }"

            local result
            result=$(curl -s -X POST -H "$auth" -H "Content-Type: application/json" "$api" -d "$payload")
            if echo "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if 'id' in d else 1)" 2>/dev/null; then
                info "  ${name}: registered"
            else
                info "  WARN: ${name}: failed to register"
            fi
        }

        add_prowlarr_app "Sonarr" "Sonarr" "SonarrSettings" \
            "http://sonarr:8989" "$sonarr_key" \
            "[5000,5010,5020,5030,5040,5045,5050,5090]" \
            ',{"name":"animeSyncCategories","value":[5070]},{"name":"syncAnimeStandardFormatSearch","value":true}'

        add_prowlarr_app "Sonarr Anime" "Sonarr" "SonarrSettings" \
            "http://sonarr-anime:8989" "$sonarr_anime_key" \
            "[5000,5010,5020,5030,5040,5045,5050,5090]" \
            ',{"name":"animeSyncCategories","value":[5070]},{"name":"syncAnimeStandardFormatSearch","value":true}'

        add_prowlarr_app "Radarr" "Radarr" "RadarrSettings" \
            "http://radarr:7878" "$radarr_key" \
            "[2000,2010,2020,2030,2040,2045,2050,2060,2070,2080,2090]"

        add_prowlarr_app "Lidarr" "Lidarr" "LidarrSettings" \
            "http://lidarr:8686" "$lidarr_key" \
            "[3000,3010,3030,3040,3050,3060]"

        add_prowlarr_app "Readarr" "Readarr" "ReadarrSettings" \
            "http://readarr:8787" "$readarr_key" \
            "[3030,7000,7010,7020,7030,7040,7050,7060]"

        info "Prowlarr application sync configured (fullSync mode)"
    }

    # -- Config backup cron
    setup_backup() {
        info "Setting up configuration backup"

        mkdir -p "$MOUNT_POINT/backup/media-stack"

        cat > /usr/local/bin/media-stack-backup.sh <<'BACKUP'
#!/usr/bin/env bash
# Back up media stack config databases
set -euo pipefail
BACKUP_DIR="/mnt/storage/backup/media-stack"
DATE=$(date +%Y%m%d-%H%M%S)
DEST="${BACKUP_DIR}/${DATE}"
mkdir -p "$DEST"

for svc in prowlarr sonarr radarr lidarr readarr; do
    vol_path=$(docker volume inspect "${svc}-config" --format '{{.Mountpoint}}' 2>/dev/null) || continue
    if [[ -f "${vol_path}/${svc}.db" ]]; then
        cp "${vol_path}/${svc}.db" "${DEST}/${svc}.db"
    elif [[ -f "${vol_path}/${svc^}.db" ]]; then
        cp "${vol_path}/${svc^}.db" "${DEST}/${svc}.db"
    fi
done

# Keep last 14 days of backups
find "$BACKUP_DIR" -maxdepth 1 -type d -mtime +14 -exec rm -rf {} +
echo "$(date): Backup complete -> $DEST"
BACKUP
        chmod 755 /usr/local/bin/media-stack-backup.sh

        # Daily backup at 3 AM
        cat > /etc/systemd/system/media-stack-backup.service <<'BSVC'
[Unit]
Description=Media stack config backup

[Service]
Type=oneshot
ExecStart=/usr/local/bin/media-stack-backup.sh
BSVC

        cat > /etc/systemd/system/media-stack-backup.timer <<'BTIMER'
[Unit]
Description=Daily media stack config backup

[Timer]
OnCalendar=*-*-* 03:00:00
Persistent=true

[Install]
WantedBy=timers.target
BTIMER

        systemctl daemon-reload
        systemctl enable media-stack-backup.timer
        systemctl start media-stack-backup.timer
        info "Backup timer installed: daily at 03:00"
    }

    # -- Verify
    verify() {
        info "Verifying media-stack LXC"

        mountpoint -q "$MOUNT_POINT" || err "NAS not mounted at $MOUNT_POINT"
        info "NAS mounted at $MOUNT_POINT"

        docker compose -f "$COMPOSE_DIR/docker-compose.yml" ps --format '{{.Service}} {{.State}}' \
            | while read -r svc state; do
                [[ "$state" == "running" ]] || err "Service $svc is $state, expected running"
                info "  ${svc}: running"
            done
        info "All Docker services running"

        for port in 9696 8989 8990 7878 8686 8787; do
            curl -sf "http://localhost:${port}/ping" &>/dev/null \
                || info "  WARN: port ${port} not responding yet (service may still be starting)"
        done

        info "Verification passed"
    }

    # -- Run in-container setup
    configure_apt_proxy
    install_docker
    setup_media_user
    setup_nfs_mount
    write_compose
    setup_qbittorrent_categories
    start_services
    configure_prowlarr_sync
    setup_backup
    verify

    cat <<EOF

================================================================
media-stack LXC setup complete ($LOCAL_IP).

Services:
  Prowlarr:      http://$LOCAL_IP:9696
  Sonarr:        http://$LOCAL_IP:8989
  Sonarr Anime:  http://$LOCAL_IP:8990
  Radarr:        http://$LOCAL_IP:7878
  Lidarr:    http://$LOCAL_IP:8686
  Readarr:   http://$LOCAL_IP:8787

Storage:     $NAS_EXPORT (NFS mount at $MOUNT_POINT)
  Downloads: $MOUNT_POINT/bittorrent/complete/{sonarr,radarr,lidarr,readarr}
  TV:        $MOUNT_POINT/video/TV Shows/
  Movies:    $MOUNT_POINT/video/Movies/
  Music:     $MOUNT_POINT/music/
  Books:     $MOUNT_POINT/books/

qBittorrent: http://$QBIT_HOST:$QBIT_PORT (categories configured)
Backups:     $MOUNT_POINT/backup/media-stack/ (daily at 03:00, 14-day retention)
================================================================
EOF
}

# ===================================================================
# Host-side: create CT and deploy (runs on the Proxmox host)
# ===================================================================

host_main() {
    source "$SCRIPT_DIR/lib/common.sh"
    [[ $EUID -eq 0 ]] || err "Run as root"

    local ctid=119
    local hostname="media-stack"
    local ip="192.168.1.${ctid}"
    local deploy_only=0
    [[ "${1:-}" == "--deploy-only" ]] && deploy_only=1

    if [[ $deploy_only -eq 0 ]]; then
        if create_lxc "$ctid" "$hostname" "$ip" 4096 4 16 "$VPN_GATEWAY_IP" "yes" \
                --nameserver "$VPN_GATEWAY_IP"; then
            pct start "$ctid"
            info "CREATED: CT $ctid ($hostname) at $ip"
        fi
    fi

    # Verify CT is running before deploying
    if ! pct status "$ctid" 2>/dev/null | grep -q "running"; then
        pct start "$ctid" 2>/dev/null || err "CT $ctid is not running and could not be started"
    fi

    info "Deploying $hostname configuration (CT $ctid)"
    deploy_script "$ctid" "$SCRIPT_DIR/12-setup-media-stack.sh"
}

# ===================================================================
# Dispatch: host-side vs in-container
# ===================================================================

if [[ "${1:-}" == "--configure" ]]; then
    configure
else
    host_main "$@"
fi
