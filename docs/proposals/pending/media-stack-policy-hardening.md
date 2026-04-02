# Proposal: Media Stack Policy Hardening

## Problem

Default Arr configurations accept overly broad results. Without quality profiles, size constraints, keyword filters, and category restrictions, the stack will grab wrong content (wrong media type, spam, low-quality, mismatched metadata). Collection workflows such as full discography, full series, and full author catalogs are especially prone to broad-query mismatches.

## Goals

- Prevent wrong-content acquisition through quality profiles, keyword filters, and category restrictions
- Establish consistent naming conventions compatible with Plex/Emby
- Create a feedback loop that auto-blocklists failed or mismatched releases

## Approach

1. Define quality profiles per media type with min/max size constraints, minimum seeders, and codec/source preferences
2. Configure required-words rules for expected matches per media type
3. Configure blocked-words rules to exclude unwanted content (spam tags, wrong categories)
4. Add custom format scoring for source, codec, and release group preferences. Prefer trusted release groups.
5. Music: restrict to music categories, block adult/video markers
6. TV/Movies: block low-quality/spam tags unless explicitly allowed
7. Books: restrict to book/audiobook categories only
8. Require artist/title/author alignment for collection workflows
9. Auto-blocklist failed or mismatched releases to prevent repeat grabs
10. Disable broad uncategorized feeds, set indexer priority and timeout/retry policy
11. Enable rename-on-import with Plex/Emby-compatible templates:
    - Series: `Series Title (Year)/Season 01/...`
    - Movies: `Movie Title (Year)/...`
    - Music: `Artist/Album (Year)/...`
    - Books: `Author/Series/Book Title (Year)`
12. Use hardlinks if seeding continuity is required
13. Standardize invalid-character replacement across all naming templates

### Changes

| File | Change |
|------|--------|
| Sonarr config | Quality profiles, custom formats, naming templates, blocked/required words for TV |
| Radarr config | Quality profiles, custom formats, naming templates, blocked/required words for movies |
| Lidarr config | Quality profiles, custom formats, naming templates, blocked/required words for music |
| Readarr config | Quality profiles, naming templates, blocked/required words for books/audiobooks |
| Prowlarr config | Indexer restrictions, category mapping enforcement, priority and timeout settings |
| Documentation | Naming template reference, quality profile rationale, blocked-word list |

## Acceptance Criteria

- [ ] Quality profiles configured per media type with min/max size constraints
- [ ] Blocked-words and required-words rules active in all Arr apps
- [ ] Custom format scoring active with source/codec/release group preferences
- [ ] Category restrictions enforced per media type (music to music, books to books, etc.)
- [ ] Rename-on-import enabled with correct Plex/Emby-compatible templates
- [ ] Hardlink behavior configured where seeding continuity is needed
- [ ] Invalid-character replacement standardized
- [ ] Blocklist feedback loop active (failed/mismatched releases auto-blocklisted)
- [ ] Uncategorized feeds disabled, indexer priority and timeout policy set

## Owner and Effort

- **Owner:** Media Ops
- **Effort:** M
- **Dependencies:** media-stack-service-deployment

## Rollout and Rollback

**Rollout:** Apply quality profiles and naming templates first (low risk). Then enable blocked/required words progressively, starting with the most obvious filters. Monitor for false positives before tightening further. Enable auto-blocklist last, after confidence in filter accuracy.

**Rollback:** Revert quality profiles to defaults. Disable blocked/required words. Disable auto-blocklist. Naming templates can remain in place as they do not affect acquisition behavior.

## Test Plan

- [ ] Verify quality profiles reject releases outside min/max size bounds
- [ ] Verify blocked-words rules prevent known spam/wrong-content patterns
- [ ] Verify required-words rules enforce expected content markers
- [ ] Verify custom format scoring ranks preferred releases higher
- [ ] Verify category restrictions prevent cross-media-type grabs
- [ ] Verify rename-on-import produces correct folder/file structure per media type
- [ ] Verify hardlinks are created when seeding continuity is active
- [ ] Verify auto-blocklist prevents re-grabbing of previously failed releases
- [ ] Test collection workflow (full series/discography) for mismatch resistance

## Operational Impact

**Metrics:** Rejection rate per filter type, blocklist growth rate, rename success rate, collection workflow accuracy.

**Logging:** Each Arr app logs rejected releases with reason. Prowlarr logs indexer query results and category mapping decisions.

**Alerts:** Spike in rejections may indicate an indexer issue or overly aggressive filters. Alert thresholds to be defined in Phase 4.

**Disk/CPU/Memory:** Negligible additional resource usage. Quality profiles and filters are evaluated in-memory during search. Rename-on-import adds brief CPU/IO during file move/hardlink operations.

## Priority

| Dimension | Value |
|-----------|-------|
| Priority | P1 |
| Impact | High (prevents wrong-content acquisition) |
| Urgency | High (required before production use) |
| Risk | Medium (overly aggressive filters may block legitimate content) |

## Trade-offs

- Strict quality profiles reduce selection but prevent low-quality imports
- Blocked-words filters may occasionally reject legitimate releases if tags overlap with spam patterns
- Auto-blocklist prevents repeat failures but requires periodic review to avoid permanently blocking sources that had transient issues
- Hardlinks preserve seeding ability but add filesystem complexity and require same-filesystem storage
- Standardized naming improves library compatibility but requires re-importing any existing content that does not match the new templates
