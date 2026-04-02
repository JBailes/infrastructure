# Proposal: Media Stack Service Deployment

## Problem

No automated media discovery/acquisition pipeline exists. Manual search, download, and rename workflows across TV, movies, music, and books are error-prone and time-consuming. The existing qBittorrent instance handles downloads but has no orchestration layer connecting it to media management tools.

## Goals

- Deploy a complete media automation stack with centralized indexer management
- Connect all media managers to the existing qBittorrent instance with proper category isolation
- Establish secure, health-checked services with aligned permissions and backup procedures

## Approach

1. Deploy Prowlarr as centralized indexer manager with approved indexers only
2. Deploy Sonarr (TV), Radarr (movies), Lidarr (music), Readarr (books/audiobooks)
3. Connect all Arr apps to existing qBittorrent with category-based paths (sonarr, radarr, lidarr, readarr categories)
4. Separate incomplete vs completed download directories, with dedicated library paths per media type
5. Configure Prowlarr category mapping: Movies to Radarr, TV to Sonarr, Music to Lidarr, Books to Readarr
6. Add health checks and restart policies for all services
7. Harden qBittorrent: strong WebUI authentication, network restrictions, ratio/seeding policy
8. Align UID/GID across all services, configure dedicated volumes, set free-space thresholds
9. Back up configuration databases on a regular schedule

### Changes

| File | Change |
|------|--------|
| `infrastructure/media-stack/docker-compose.yml` | Service definitions for Prowlarr, Sonarr, Radarr, Lidarr, Readarr with health checks and restart policies |
| `infrastructure/media-stack/qbittorrent-config/` | Category paths, authentication settings, network restrictions, ratio/seeding policy |
| `infrastructure/media-stack/.env.example` | Non-secret configuration template (UIDs, GIDs, paths, ports, free-space thresholds) |

## Acceptance Criteria

- [ ] All services deployed and passing health checks
- [ ] Prowlarr connected to approved indexers with correct category mapping
- [ ] Each Arr app connected to qBittorrent with its own download category
- [ ] WebUI authentication secured on all services
- [ ] UID/GID aligned across all services and volumes
- [ ] Single-item acquisition test passes for each media type (TV, movie, music, book)
- [ ] Configuration databases backed up and restore verified

## Owner and Effort

- **Owner:** Infra
- **Effort:** M
- **Dependencies:** media-stack-network-security

## Rollout and Rollback

**Rollout:** Deploy services incrementally. Start with Prowlarr, verify indexer connectivity, then deploy each Arr app one at a time. Validate each connection before proceeding.

**Rollback:** Stop and remove containers via docker-compose down. Restore qBittorrent config from backup if modified. No changes to existing library data are made during deployment, so rollback carries no data loss risk.

## Test Plan

- [ ] Verify each service starts and passes its health check
- [ ] Verify Prowlarr can reach all configured indexers
- [ ] Verify each Arr app can authenticate to qBittorrent
- [ ] Verify category-based download paths are created correctly
- [ ] Execute single-item acquisition test per media type
- [ ] Verify UID/GID alignment by checking file ownership on imported items
- [ ] Verify config database backup and restore procedure

## Operational Impact

**Metrics:** Service uptime, indexer response times, qBittorrent queue depth per category.

**Logging:** Each service writes logs to its own volume. Aggregate via docker logs or centralized logging in a later phase.

**Alerts:** Health check failures trigger container restart. Persistent failures require manual investigation (alerting covered in Phase 4).

**Disk/CPU/Memory:** Each Arr app uses approximately 100-300 MB RAM at idle. Prowlarr is lightweight. qBittorrent resource usage unchanged. Disk usage for config databases is minimal (< 500 MB total). Library storage depends on acquired media.

## Priority

| Dimension | Value |
|-----------|-------|
| Priority | P1 |
| Impact | High |
| Urgency | High |
| Risk | Low (no existing data modified) |

## Trade-offs

- Deploying all four Arr apps at once increases initial setup effort but avoids repeated integration work later
- Using category-based qBittorrent paths adds configuration complexity but prevents cross-media download collisions
- Aligning UID/GID requires upfront coordination but eliminates permission issues across services
- Backing up config databases adds a maintenance task but protects against data loss during upgrades or failures
