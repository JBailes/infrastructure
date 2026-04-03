# Proposal: Media Stack Validation and Handoff

## Problem

Without systematic validation, the stack may silently import wrong content or fail to import correct content. Without monitoring and runbooks, operational issues require manual investigation with no alerting or documented procedures.

## Goals

- Validate the entire media stack through a controlled positive/negative test matrix
- Establish monitoring dashboards and alerting for ongoing operations
- Document runbooks for common operational scenarios
- Achieve formal sign-off for production use

## Approach

### Phase 3: Validation

1. Execute controlled positive/negative test matrix per media type
2. Enable qBittorrent hash recheck in the remediation path
3. Enable Arr import verification: reject title/year/artist/author mismatches
4. Validate file container/extension against media type
5. Quarantine mismatches for manual review
6. Tune thresholds based on false positive/negative rates from the test matrix
7. Finalize blocklist feedback behavior (auto-blocklist repeated failures)
8. Full-collection mode test (series/discography/author) in a controlled dataset
9. Negative tests for known wrong-content query patterns
10. Naming/import verification against Plex/Emby conventions

### Phase 4: Handoff

1. Centralize logs for Prowlarr, Arr apps, and qBittorrent
2. Create dashboards: queue depth, failures, import success rate, mismatch rate
3. Alert on: indexer failures, client outages, repeated import failures, route drift
4. Review blocked/rejected release metrics weekly
5. Document upgrade runbook and rollback process
6. Document incident runbook for failed imports and mismatch spikes
7. Validate backups and restore in staging
8. Provide safe-mode procedure (pause automation, manual approval only)
9. Formal infra + operations sign-off

### Go-live Checks

- Single-item acquisition test per media type
- Full-collection test in a controlled dataset
- Negative tests for wrong-content patterns
- Naming verification against Plex/Emby
- Simulated VPN outage confirms fail-closed
- Verified block of 192.168.1.1
- Formal sign-off from infra and operations

### Changes

| File | Change |
|------|--------|
| `infrastructure/media-stack/tests/` | Test matrix scripts for positive/negative validation per media type |
| `infrastructure/media-stack/monitoring/` | Dashboard configurations and alert rules |
| `infrastructure/media-stack/runbooks/` | Operations, incident response, restore, and upgrade documentation |

## Acceptance Criteria

- [ ] Positive/negative test matrix executed and passing for all media types
- [ ] Import verification active and rejecting title/year/artist/author mismatches
- [ ] Mismatch quarantine working with manual review queue
- [ ] Dashboards deployed showing queue depth, failures, import success rate, mismatch rate
- [ ] Alerts configured for indexer failures, client outages, repeated import failures, route drift
- [ ] Upgrade runbook documented and tested
- [ ] Incident runbook documented for failed imports and mismatch spikes
- [ ] Backup restore verified in staging
- [ ] Safe-mode procedure documented and tested
- [ ] Go-live checklist completed
- [ ] Import success rate >= 95%
- [ ] Wrong-content rate <= 2%
- [ ] Fail-closed behavior verified under simulated VPN outage

## Owner and Effort

- **Owner:** Infra + Media Ops
- **Effort:** L
- **Dependencies:** media-stack-policy-hardening

## Rollout and Rollback

**Rollout:** Phase 3 runs entirely in a controlled test environment before any production traffic. Phase 4 monitoring and runbooks are deployed alongside existing services with no behavioral changes. Go-live checks are executed as a final gate before formal handoff.

**Rollback:** Activate safe-mode (pause all automation, require manual approval). If issues persist, stop Arr app services while leaving qBittorrent and media libraries intact. Monitoring and alerting remain active during rollback to track resolution.

## Test Plan

- [ ] Execute positive test: acquire one known-good item per media type, verify correct import and naming
- [ ] Execute negative test: search for known wrong-content patterns, verify rejection
- [ ] Execute full-collection test: acquire a small series/discography/author set, verify completeness and accuracy
- [ ] Verify quarantine: trigger a mismatch, confirm item lands in quarantine queue
- [ ] Verify hash recheck: corrupt a download, confirm recheck and re-download
- [ ] Verify dashboards: confirm all metrics populate correctly
- [ ] Verify alerts: simulate indexer failure, confirm alert fires
- [ ] Verify safe-mode: activate safe-mode, confirm automation pauses
- [ ] Verify backup restore: restore config databases from backup in staging
- [ ] Simulate VPN outage: confirm all traffic stops (fail-closed)

## Operational Impact

**Metrics:**
- Import success rate (target >= 95%)
- Wrong-content rejection rate (target <= 2%)
- Manual intervention rate
- Mean time to recover from failed acquisitions
- Policy drift incidents (unexpected configuration changes)

**Logging:** Centralized log aggregation for all stack components. Structured logs for import decisions, rejections, and quarantine actions.

**Alerts:**
- Indexer failure (any indexer unreachable for > 5 minutes)
- Client outage (qBittorrent unreachable)
- Repeated import failures (> 3 failures in 1 hour for same item)
- Route drift (unexpected network path changes)
- Import success rate drops below 90%

**Disk/CPU/Memory:** Monitoring adds minimal overhead (log shipping and metric collection). Test matrix execution is a one-time burst. Dashboards and alert evaluation are lightweight. No significant ongoing resource increase beyond Phase 2 baseline.

## Priority

| Dimension | Value |
|-----------|-------|
| Priority | P1 |
| Impact | High (required for production confidence) |
| Urgency | High (blocks production handoff) |
| Risk | Low (validation and monitoring do not modify acquisition behavior) |

## Trade-offs

- Comprehensive test matrix increases validation time but catches issues before production
- Quarantine adds a manual review burden but prevents wrong content from reaching libraries
- Centralized logging increases storage usage but enables faster incident investigation
- Strict alert thresholds may generate noise initially but can be tuned after baseline establishment
- Formal sign-off process adds procedural overhead but ensures accountability and readiness
- The >= 95% import success target is achievable but may require iterative tuning of Phase 2 policies
