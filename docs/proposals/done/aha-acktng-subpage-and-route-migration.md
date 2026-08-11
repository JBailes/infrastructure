# Proposal: ACK!TNG Sub-Page on AHA and Full Route Migration from WOL

> **Historical proposal.** This document records a design as it was proposed and
> implemented at the time. Host identities in the prose have been updated to the
> CTIDs and hostnames currently in use, so the containers named here can still be
> located. Code blocks are left verbatim and still contain the literal addresses
> and CTIDs used at the time -- do not copy them without checking. Some of what is
> described has since changed or been removed; see
> [architecture.md](../../../architecture.md) for what actually runs today.


## Status
Pending approval.

## Problem

Following the site identity split (web PR #50), `ackmud.com` (WOL) still owns all content routes:
who's online, world map, stories, and the full reference section (help/shelp/lore). These are
all historical ACK!TNG assets and belong on `aha.ackmud.com`. WOL should be a minimal coming-soon
page until the World of Lore game server is live.

## Approach

### 1. New ACK!TNG sub-page on AHA (`/acktng/`)

A dedicated landing page at `aha.ackmud.com/acktng/` introducing ACK!TNG as the final release
of the TNG lineage, now archived. Links to MUD client, who's online, reference, stories, and map.

### 2. Migrate all content routes from WOL to AHA

| Route | Current | After |
|---|---|---|
| `/who/`, `/players/` | WOL 200 | AHA 200, WOL 404 |
| `/map/`, `/world-map/` | WOL 200 | AHA 200, WOL 404 |
| `/stories/` | WOL 200 | AHA 200, WOL 404 |
| `/reference/*` | WOL 200 | AHA 200, WOL 404 |
| `/helps/<topic>` | WOL 200 | AHA 200, WOL 404 |
| `/shelps/<topic>` | WOL 200 | AHA 200, WOL 404 |
| `/lores/<topic>` | WOL 200 | AHA 200, WOL 404 |
| `/gsgp/` | WOL 200 | AHA 200, WOL 404 |
| `/help/` → `/reference/help/` (redirect) | WOL | AHA |
| `/shelp/` → `/reference/shelp/` (redirect) | WOL | AHA |
| `/lore/` → `/reference/lore/` (redirect) | WOL | AHA |
| `/acktng/` | -- | AHA 200 (new) |

### 3. Simplify WOL to coming-soon

`_handle_wol_route` retains only:
- `/` -- coming-soon home (already drafted in home_wol.html; WOL nav link to AHA already exists)
- `/home`, `/home/` → redirect to `/`

All other WOL routes return 404.

### 4. Navigation updates

**`_WOL_NAV`** -- strip down to: Home · Discord · Historical Archive (aha.ackmud.com)

**`_AHA_NAV`** -- expand to: Home · ACK!TNG · Who · MUD Client · Map · Stories · Reference · Discord · GitHub · World of Lore (ackmud.com)

### 5. New template: `templates/acktng.html`

Content: introduces ACK!TNG (The Next Generation) as a now-archived final release. Cards linking to Who, MUD Client, Reference, Stories, Map.

## Affected Files

- `web/web_who_server.py` -- route logic, nav constants, `_handle_wol_route`, `_handle_aha_route`
- `web/templates/home_wol.html` -- minor: nav already has AHA link; may simplify further
- `web/templates/acktng.html` -- new file
- `web/test_integration.py` -- flip all AHA 404 tests to 200, flip WOL content route tests to 404, add ACK!TNG sub-page test, move redirect tests to AHA

## Trade-offs

- All existing WOL deep-links (e.g. bookmarked `/reference/help/`) will 404. No redirect from WOL to AHA equivalents -- users will need to navigate to AHA.
- The `/gsgp/` endpoint (used by any external GSGP clients pointing at ackmud.com) will break on WOL. If anything external relies on it, they will need to update to `aha.ackmud.com/gsgp/`.
