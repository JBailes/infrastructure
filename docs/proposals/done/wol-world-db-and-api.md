# Proposal: WOL World Database and API Server

**Status:** Pending
**Date:** 2026-03-25
**Affects:** `wol/`, new `wol-world` repo (API + DB), PostgreSQL, `CLAUDE.md`
**Depends on:** `proposals/active/Infrastructure/wol-accounts-db-and-api.md` (mTLS/SPIFFE architecture), `proposals/active/Infrastructure/private-ca-and-secret-management.md` (private CA)

---

## Problem

WOL has no persistent storage for the game world. Rooms, objects, NPCs, exits, area definitions, shop configurations, loot tables, spawn rules, and all other world-building data have no database or API. Without this, WOL cannot load or run any game content.

The legacy acktng server stores world data in flat area files and a PostgreSQL database with tightly coupled tables. WOL needs a clean, service-separated world store designed from the start so that individual table groups can be split into separate databases as the game scales.

---

## Scope

This proposal covers **world prototype data**: the definitions and templates that describe what the world looks like. It does not cover runtime instance state (spawned NPC health, dropped item locations, active room effects). Runtime state lives in WOL's memory and is a future proposal.

**Stored here (prototypes and definitions):**
- Areas (grouping, metadata, level ranges, reset configuration)
- Rooms (locations, descriptions, sector types, flags)
- Exits (directional connections between rooms)
- Extra descriptions (searchable keywords on rooms and objects)
- Object prototypes (item templates: weapons, armor, containers, keys, potions, etc.)
- Object stat affects (modifiers applied when equipped)
- NPC prototypes (monster/shopkeeper templates: stats, flags, AI prompts)
- NPC loot tables (what objects an NPC can drop)
- NPC scripts (trigger-based behaviour)
- Shops (merchant configuration)
- Resets (spawn rules: which NPCs and objects appear in which rooms)

**Not stored here (out of scope):**
- Runtime instance state (spawned NPC HP, dropped item positions, active buffs)
- Player inventory and equipment (future character-state proposal)
- Quest definitions and quest state
- Clan data
- Help entries and lore entries
- Skills and spells definitions

---

## Deployment Architecture

**The world API server and its PostgreSQL database server are separate machines.** The world API is not public-facing; it runs on a private network reachable only from trusted internal services.

Multiple WOL realm servers share the same world API. The world API has no concept of which realm is requesting data; it serves the canonical world definition to all callers.

```
WOL Realm A ──┐
              ├── HTTPS + JWT-SVID ──▶ wol-world API server  [private network]
WOL Realm B ──┘                              │
                                        Npgsql + mTLS
                                             │
                                         PostgreSQL server (world)  [private network, separate machine]
```

### World data loading pattern

Unlike the accounts and players APIs (which handle per-request lookups), the world API serves **bulk data at startup**. WOL loads the entire world into memory when it boots and runs from that in-memory state. The API is called:

1. **At WOL startup:** bulk-load all areas, rooms, exits, object prototypes, NPC prototypes, resets, shops, scripts, loot tables, extra descriptions, and object affects.
2. **On builder changes (future):** hot-reload a single area's data without full restart.

This means the API must support efficient bulk retrieval. Individual-entity endpoints exist for builder tools and administrative operations, but the primary consumer (WOL) uses bulk endpoints.

### Reliability

WOL depends on the world API **only at startup and during area reloads**. Once the world is loaded into memory, WOL operates independently. If the world API goes down during normal gameplay, running realms are unaffected. A realm that attempts to start or reload an area while the API is unavailable will fail to start.

The same reliability baseline as other services applies:
- `systemd` unit with `Restart=always`, `RestartSec=2s`
- `/health` endpoint polled by monitoring
- Fast-restart runbook

### Private network communication policy

Identical to the accounts and players proposals. All links use mTLS with SPIFFE/SPIRE. See `wol-accounts-db-and-api.md` and `spiffe-spire-workload-identity.md`. The authorization matrix, SPIFFE ID matching algorithm, JWT-SVID replay protection, and rate limiting policy are defined in `infrastructure/identity-and-auth-contract.md`.

---

## Domain Model

The world data is organised into five logical domains. Each domain is a group of tables that reference each other with proper foreign keys internally. **Cross-domain references use plain BIGINT columns with no foreign key constraints.** This is the mechanism that allows any domain to be moved to a separate database in the future without breaking FK constraints.

### Domain boundaries

| Domain | Tables | Cross-domain references (BIGINT, no FK) |
|--------|--------|-----------------------------------------|
| **Areas** | `areas` | (none, referenced by others) |
| **Rooms** | `rooms`, `room_exits`, `room_extra_descs` | `rooms.area_id` -> areas, `room_exits.destination_room_id` -> rooms (cross-domain if rooms are split by area), `room_exits.key_object_id` -> object_prototypes |
| **Objects** | `object_prototypes`, `object_extra_descs`, `object_affects` | `object_prototypes.area_id` -> areas |
| **NPCs** | `npc_prototypes`, `npc_loot`, `npc_scripts`, `shops` | `npc_prototypes.area_id` -> areas, `npc_loot.object_prototype_id` -> object_prototypes |
| **Resets** | `resets` | `resets.area_id` -> areas, references to rooms/NPCs/objects by ID |

**Within-domain FK example:** `room_exits.room_id` has a proper `REFERENCES rooms(id)` constraint because both tables are in the Rooms domain.

**Cross-domain reference example:** `rooms.area_id` is a plain `BIGINT NOT NULL` with no FK constraint because `areas` is in a different domain.

### Future splitting

To split the Objects domain into its own database:
1. Create a new PostgreSQL database with the `object_prototypes`, `object_extra_descs`, and `object_affects` tables.
2. Deploy a new API server for that database.
3. Update WOL to call the objects API for object data.
4. Remove the object tables from the world database.

No schema migrations are needed on the remaining tables because no FK constraints reference the moved tables. The API layer (or WOL itself) enforces cross-domain consistency.

### Cross-domain consistency

Without FK constraints, cross-domain references can become stale (e.g., a room's `area_id` pointing to a deleted area, or a reset referencing a removed NPC prototype). Mitigations:

- **Write-time validation:** The API validates that referenced entities exist before accepting writes. For example, creating a room checks that the `area_id` exists; creating a reset checks that the referenced NPC/object/room exists.
- **Bulk-load validation:** WOL's startup bulk-load logs warnings for any dangling cross-domain references (e.g., a room_exit pointing to a nonexistent destination_room_id). These are non-fatal but flagged for builder attention.
- **Periodic sweep (future):** A scheduled consistency check queries all cross-domain references and reports orphans. This is out of scope for the initial implementation but required before the first domain split.

---

## Security Model

### Per-request authorisation and mTLS

Identical to the accounts and players proposals. WOL obtains a JWT-SVID from its local SPIRE Agent with audience `spiffe://wol/world` and includes it as `Authorization: Bearer <jwt-svid>`. mTLS provides transport-layer mutual authentication. See `spiffe-spire-workload-identity.md` Section 4.

### Rate limiting

**Per-caller SPIFFE ID:** default 120 requests/minute per caller. The world API handles fewer, larger requests than accounts/players (bulk loads rather than per-player lookups), so the limit is higher per-request but lower in total volume.

Rate limit violations return `429 Too Many Requests`.

### Audit logging

Structured JSON log lines to stdout for all write operations:
- Area/room/object/NPC created, updated, deleted (entity type, ID, timestamp)
- Reset created, updated, deleted (area_id, ID, timestamp)

Read operations are not logged individually (bulk loads would overwhelm the log). The `/health` endpoint is unauthenticated.

CORS is explicitly disabled.

---

## New Repo: `wol-world`

Standalone C#/.NET service and independent git repository.

### Directory layout

```
wol-world/
  src/
    Wol.World/
      Program.cs                  # ASP.NET Core minimal API, routes, DI, Kestrel config
      Wol.World.csproj
  migrations/
    001_initial.sql
  tools/
    Wol.World.Migrate/
      Program.cs                  # Migration runner (Npgsql, wol_world_migrate user, deployment step)
      Wol.World.Migrate.csproj
  tests/
    Wol.World.Tests/
      AreaTests.cs
      RoomTests.cs
      ObjectTests.cs
      NpcTests.cs
      ResetTests.cs
      Wol.World.Tests.csproj
  .env.example
  README.md
```

### Database users

| User | Permissions | Purpose |
|------|-------------|---------|
| `wol_world_migrate` | DDL, GRANT; ownership of all tables; full access to `schema_migrations`; mTLS client cert | Deployment-step migrations |
| `wol_world` | `SELECT/INSERT/UPDATE/DELETE` on all world tables and sequences; no DDL; mTLS client cert | Running API server |

The database is named `wol_world` and runs on a dedicated PostgreSQL server, separate from the world API server and separate from the accounts and players database servers.

### Schema migration process

Identical to the accounts and players proposals. Deployment step, not API startup:

```
dotnet run --project tools/Wol.World.Migrate
```

using `wol_world_migrate` credentials injected at deploy time and discarded after.

```sql
CREATE TABLE IF NOT EXISTS schema_migrations (
    filename   TEXT        PRIMARY KEY,
    applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

---

## Database Schema

All cross-domain references are marked with `-- xref: <domain>` comments. These columns are plain BIGINT with no FK constraint.

### Domain: Areas

```sql
CREATE TABLE areas (
    id              BIGSERIAL    PRIMARY KEY,
    name            TEXT         NOT NULL,
    level_min       INT          NOT NULL DEFAULT 0   CHECK (level_min >= 0),
    level_max       INT          NOT NULL DEFAULT 0   CHECK (level_max >= 0),
    reset_rate_min  INT          NOT NULL DEFAULT 15  CHECK (reset_rate_min > 0),  -- minutes between resets
    reset_message   TEXT,                                 -- broadcast to players in area on reset
    flags           TEXT[]       NOT NULL DEFAULT '{}',   -- e.g., ARRAY['no_teleport', 'pay_area']
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);
```

### Domain: Rooms

```sql
CREATE TABLE rooms (
    id              BIGSERIAL    PRIMARY KEY,
    area_id         BIGINT       NOT NULL,                -- xref: areas
    name            TEXT         NOT NULL,
    description     TEXT         NOT NULL DEFAULT '',
    sector_type     TEXT         NOT NULL DEFAULT 'field' CHECK (length(sector_type) > 0), -- validated by API allowlist: city, field, forest, hills, etc.
    flags           TEXT[]       NOT NULL DEFAULT '{}',    -- e.g., ARRAY['dark', 'no_mob', 'safe', 'indoors']
    light_level     INT          NOT NULL DEFAULT 0,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE INDEX rooms_area_id_idx ON rooms (area_id);

CREATE TABLE room_exits (
    id                    BIGSERIAL  PRIMARY KEY,
    room_id               BIGINT     NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
    direction             TEXT       NOT NULL CHECK (direction IN ('north', 'east', 'south', 'west', 'up', 'down')),
    destination_room_id   BIGINT     NOT NULL,            -- xref: rooms (may be in a different area)
    flags                 TEXT[]     NOT NULL DEFAULT '{}', -- e.g., ARRAY['door', 'closed', 'locked', 'pickproof']
    key_object_id         BIGINT,                         -- xref: object_prototypes (key required to unlock)
    keyword               TEXT,                           -- door keyword (e.g., 'iron gate')
    description           TEXT,                           -- what you see when you look at the exit
    UNIQUE (room_id, direction)
);

CREATE INDEX room_exits_room_id_idx ON room_exits (room_id);

CREATE TABLE room_extra_descs (
    id          BIGSERIAL  PRIMARY KEY,
    room_id     BIGINT     NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
    keyword     TEXT       NOT NULL,         -- searchable keyword(s)
    description TEXT       NOT NULL
);

CREATE INDEX room_extra_descs_room_id_idx ON room_extra_descs (room_id);
```

### Domain: Objects

```sql
CREATE TABLE object_prototypes (
    id                BIGSERIAL    PRIMARY KEY,
    area_id           BIGINT       NOT NULL,              -- xref: areas
    keywords          TEXT         NOT NULL,               -- space-separated keywords (e.g., 'blade black coral weapon')
    short_description TEXT         NOT NULL,               -- shown in inventory/combat (e.g., 'a blade of black coral')
    description       TEXT         NOT NULL DEFAULT '',     -- detailed look description
    item_type         TEXT         NOT NULL CHECK (length(item_type) > 0), -- validated by API allowlist: weapon, armor, light, scroll, potion, etc.
    level             INT          NOT NULL DEFAULT 1  CHECK (level >= 1),
    weight            INT          NOT NULL DEFAULT 1  CHECK (weight >= 0),
    flags             TEXT[]       NOT NULL DEFAULT '{}',   -- e.g., ARRAY['magic', 'no_drop', 'two_handed', 'unique']
    wear_slots        TEXT[]       NOT NULL DEFAULT '{}',   -- e.g., ARRAY['head', 'body', 'hands', 'hold']
    values            JSONB        NOT NULL DEFAULT '{}',   -- type-specific properties (see below)
    created_at        TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at        TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE INDEX object_prototypes_area_id_idx ON object_prototypes (area_id);

CREATE TABLE object_extra_descs (
    id                    BIGSERIAL  PRIMARY KEY,
    object_prototype_id   BIGINT     NOT NULL REFERENCES object_prototypes(id) ON DELETE CASCADE,
    keyword               TEXT       NOT NULL,
    description           TEXT       NOT NULL
);

CREATE INDEX object_extra_descs_prototype_id_idx ON object_extra_descs (object_prototype_id);

CREATE TABLE object_affects (
    id                    BIGSERIAL  PRIMARY KEY,
    object_prototype_id   BIGINT     NOT NULL REFERENCES object_prototypes(id) ON DELETE CASCADE,
    stat                  TEXT       NOT NULL,            -- validated by API: str, dex, int, wis, con, hp, mana, hit_roll, dam_roll, ac, etc.
    modifier              INT        NOT NULL             -- positive or negative
);

CREATE INDEX object_affects_prototype_id_idx ON object_affects (object_prototype_id);
```

**`values` JSONB by item_type:**

Rather than 10 generic integer columns (the legacy approach), type-specific properties are stored in a JSONB column. The API validates the shape based on `item_type`. Examples:

| item_type | values example |
|-----------|---------------|
| weapon    | `{"damage_dice_count": 3, "damage_dice_sides": 8, "damage_type": "slash"}` |
| armor     | `{"ac_bonus": 5}` |
| container | `{"capacity": 100, "closeable": true, "key_object_id": 42}` |
| potion    | `{"spell_level": 10, "spells": ["cure_light", "refresh"]}` |
| light     | `{"duration_hours": 24}` |
| scroll    | `{"spell_level": 15, "spells": ["teleport"]}` |
| food      | `{"hunger_restored": 5, "poisoned": false}` |
| drink     | `{"capacity": 10, "remaining": 10, "liquid_type": "water", "poisoned": false}` |
| key       | `{}` |
| money     | `{"amount": 100}` |
| portal    | `{"destination_room_id": 3001}` |
| furniture | `{"seats": 4}` |

The `values` schema per item_type is defined in API configuration, not in the database. Adding a new item_type or changing its value schema requires an API update, not a migration.

### Domain: NPCs

```sql
CREATE TABLE npc_prototypes (
    id                BIGSERIAL    PRIMARY KEY,
    area_id           BIGINT       NOT NULL,              -- xref: areas
    keywords          TEXT         NOT NULL,               -- space-separated keywords (e.g., 'guard city warrior')
    short_description TEXT         NOT NULL,               -- shown in combat (e.g., 'the city guard')
    long_description  TEXT         NOT NULL DEFAULT '',     -- shown when NPC is standing in a room
    description       TEXT         NOT NULL DEFAULT '',     -- detailed look description
    level             INT          NOT NULL DEFAULT 1,
    sex               TEXT         NOT NULL DEFAULT 'neutral', -- neutral, male, female
    alignment         INT          NOT NULL DEFAULT 0,     -- -1000 (evil) to 1000 (good)
    race              TEXT         NOT NULL DEFAULT 'human',
    npc_class         TEXT         NOT NULL DEFAULT 'warrior',
    position          TEXT         NOT NULL DEFAULT 'standing', -- standing, sitting, sleeping, etc.
    flags             TEXT[]       NOT NULL DEFAULT '{}',   -- e.g., ARRAY['sentinel', 'aggressive', 'scavenger', 'undead']
    affected_by       TEXT[]       NOT NULL DEFAULT '{}',   -- permanent affects: ARRAY['sanctuary', 'detect_invis']
    hp_mod            INT          NOT NULL DEFAULT 0,      -- HP adjustment (-500 to 500)
    ac_mod            INT          NOT NULL DEFAULT 0,
    hr_mod            INT          NOT NULL DEFAULT 0,      -- hit roll modifier
    dr_mod            INT          NOT NULL DEFAULT 0,      -- damage roll modifier
    combat_mods       JSONB        NOT NULL DEFAULT '{}',   -- extended: {"spellpower": 0, "crit": 0, "crit_mult": 0, "parry": 0, "dodge": 0, "block": 0, ...}
    resistances       JSONB        NOT NULL DEFAULT '{}',   -- e.g., {"fire": 20, "cold": -10} (positive = resist, negative = vulnerable)
    loot_percent      INT          NOT NULL DEFAULT 0,      -- base chance of dropping loot (0-100)
    ai_prompt         TEXT,                                 -- system prompt for AI-enabled dialogue
    created_at        TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at        TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE INDEX npc_prototypes_area_id_idx ON npc_prototypes (area_id);

CREATE TABLE npc_loot (
    id                    BIGSERIAL  PRIMARY KEY,
    npc_prototype_id      BIGINT     NOT NULL REFERENCES npc_prototypes(id) ON DELETE CASCADE,
    object_prototype_id   BIGINT     NOT NULL,            -- xref: object_prototypes
    chance_percent        INT        NOT NULL DEFAULT 100, -- 1-100, chance this item drops
    seq                   INT        NOT NULL DEFAULT 0    -- evaluation order
);

CREATE INDEX npc_loot_prototype_id_idx ON npc_loot (npc_prototype_id);

CREATE TABLE npc_scripts (
    id                BIGSERIAL  PRIMARY KEY,
    npc_prototype_id  BIGINT     NOT NULL REFERENCES npc_prototypes(id) ON DELETE CASCADE,
    seq               INT        NOT NULL DEFAULT 0,      -- execution order
    trigger_type      TEXT       NOT NULL,                 -- greet, fight, death, speech, tick, entry, exit, give, etc.
    trigger_args      TEXT       NOT NULL DEFAULT '',      -- trigger-specific arguments
    commands          TEXT       NOT NULL                   -- script body
);

CREATE INDEX npc_scripts_prototype_id_idx ON npc_scripts (npc_prototype_id);

CREATE TABLE shops (
    id                BIGSERIAL  PRIMARY KEY,
    npc_prototype_id  BIGINT     NOT NULL UNIQUE REFERENCES npc_prototypes(id) ON DELETE CASCADE,
    buy_types         TEXT[]     NOT NULL DEFAULT '{}',    -- item_types this shop buys: ARRAY['weapon', 'armor']
    profit_buy        INT        NOT NULL DEFAULT 100,     -- markup when player buys (100 = base price)
    profit_sell       INT        NOT NULL DEFAULT 100,     -- markdown when player sells
    open_hour         INT        NOT NULL DEFAULT 0,       -- 0-23
    close_hour        INT        NOT NULL DEFAULT 23       -- 0-23
);
```

### Domain: Resets

```sql
CREATE TABLE resets (
    id          BIGSERIAL  PRIMARY KEY,
    area_id     BIGINT     NOT NULL,                      -- xref: areas
    seq         INT        NOT NULL DEFAULT 0,             -- execution order within area
    command     TEXT       NOT NULL,                        -- mob, object, give, equip, door, put, randomize
    condition   TEXT       NOT NULL DEFAULT 'always',       -- always, if_previous (execute only if previous reset succeeded)
    arg1        BIGINT     NOT NULL DEFAULT 0,             -- primary target (NPC/object/room ID depending on command)
    arg2        BIGINT     NOT NULL DEFAULT 0,             -- secondary (max count, door state, wear slot, etc.)
    arg3        BIGINT     NOT NULL DEFAULT 0,             -- tertiary (room ID for mob/object placement, etc.)
    notes       TEXT,                                      -- builder notes
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX resets_area_id_seq_idx ON resets (area_id, seq);
```

**Reset commands:**

| command     | arg1            | arg2        | arg3              | Description |
|-------------|-----------------|-------------|-------------------|-------------|
| `mob`       | npc_prototype_id | max_count  | room_id           | Spawn NPC in room |
| `object`    | object_prototype_id | max_count | room_id         | Place object in room |
| `give`      | object_prototype_id | max_count | (unused)         | Give object to last-spawned NPC |
| `equip`     | object_prototype_id | max_count | wear_slot_index  | Equip object on last-spawned NPC |
| `put`       | object_prototype_id | max_count | container_object_id | Put object in container |
| `door`      | room_id         | direction   | state (0=open, 1=closed, 2=locked) | Set door state |
| `randomize` | room_id         | (unused)    | (unused)          | Randomize exits |

### Permissions grants

```sql
-- Run by wol_world_migrate after table creation
GRANT SELECT, INSERT, UPDATE, DELETE ON
    areas, rooms, room_exits, room_extra_descs,
    object_prototypes, object_extra_descs, object_affects,
    npc_prototypes, npc_loot, npc_scripts, shops,
    resets
TO wol_world;

GRANT USAGE, SELECT ON
    areas_id_seq, rooms_id_seq, room_exits_id_seq, room_extra_descs_id_seq,
    object_prototypes_id_seq, object_extra_descs_id_seq, object_affects_id_seq,
    npc_prototypes_id_seq, npc_loot_id_seq, npc_scripts_id_seq, shops_id_seq,
    resets_id_seq
TO wol_world;
```

---

## API Endpoints

### Bulk loading (WOL startup)

These endpoints return complete domain data for one or all areas in a single response. They are the primary interface for WOL.

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/health` | Liveness check, unauthenticated |
| `POST` | `/bulk/snapshot` | Consistent point-in-time snapshot of all world data (single transaction, single response). Primary startup endpoint. |
| `GET` | `/bulk/areas` | All areas with metadata |
| `GET` | `/bulk/rooms?area_id={id}` | All rooms, exits, and extra descs for an area (or all areas if omitted) |
| `GET` | `/bulk/objects?area_id={id}` | All object prototypes, extra descs, and affects for an area (or all) |
| `GET` | `/bulk/npcs?area_id={id}` | All NPC prototypes, loot, scripts, and shops for an area (or all) |
| `GET` | `/bulk/resets?area_id={id}` | All resets for an area (or all) |

Each bulk endpoint returns nested data. For example, `GET /bulk/rooms?area_id=1` returns:

```json
{
  "rooms": [
    {
      "id": 3001,
      "area_id": 1,
      "name": "The Town Square",
      "description": "A bustling square...",
      "sector_type": "city",
      "flags": ["safe", "no_mob"],
      "light_level": 0,
      "exits": [
        {
          "id": 1,
          "direction": "north",
          "destination_room_id": 3002,
          "flags": [],
          "key_object_id": null,
          "keyword": null,
          "description": null
        }
      ],
      "extra_descs": [
        {
          "id": 1,
          "keyword": "fountain statue",
          "description": "A weathered stone fountain..."
        }
      ]
    }
  ]
}
```

Similarly, `GET /bulk/npcs` nests loot, scripts, and shop data into each NPC prototype response.

### CRUD endpoints (builder tools and administration)

Individual entity operations for builder tools. These follow standard REST patterns.

**Areas:**

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/areas` | List all areas |
| `GET` | `/areas/{area_id}` | Get area by ID |
| `POST` | `/areas` | Create area |
| `PATCH` | `/areas/{area_id}` | Update area |
| `DELETE` | `/areas/{area_id}` | Delete area (fails if rooms/objects/NPCs/resets still reference it) |

**Rooms:**

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/rooms?area_id={id}` | List rooms in area |
| `GET` | `/rooms/{room_id}` | Get room with exits and extra descs |
| `POST` | `/rooms` | Create room |
| `PATCH` | `/rooms/{room_id}` | Update room |
| `DELETE` | `/rooms/{room_id}` | Delete room (cascades exits and extra descs) |
| `PUT` | `/rooms/{room_id}/exits/{direction}` | Create or replace exit |
| `DELETE` | `/rooms/{room_id}/exits/{direction}` | Delete exit |
| `POST` | `/rooms/{room_id}/extra-descs` | Add extra description |
| `DELETE` | `/rooms/{room_id}/extra-descs/{id}` | Delete extra description |

**Object Prototypes:**

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/objects?area_id={id}` | List object prototypes in area |
| `GET` | `/objects/{object_id}` | Get object prototype with extra descs and affects |
| `POST` | `/objects` | Create object prototype |
| `PATCH` | `/objects/{object_id}` | Update object prototype |
| `DELETE` | `/objects/{object_id}` | Delete object prototype (cascades extra descs and affects) |
| `POST` | `/objects/{object_id}/affects` | Add stat affect |
| `DELETE` | `/objects/{object_id}/affects/{id}` | Delete stat affect |
| `POST` | `/objects/{object_id}/extra-descs` | Add extra description |
| `DELETE` | `/objects/{object_id}/extra-descs/{id}` | Delete extra description |

**NPC Prototypes:**

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/npcs?area_id={id}` | List NPC prototypes in area |
| `GET` | `/npcs/{npc_id}` | Get NPC prototype with loot, scripts, and shop |
| `POST` | `/npcs` | Create NPC prototype |
| `PATCH` | `/npcs/{npc_id}` | Update NPC prototype |
| `DELETE` | `/npcs/{npc_id}` | Delete NPC prototype (cascades loot, scripts, shop) |
| `POST` | `/npcs/{npc_id}/loot` | Add loot entry |
| `DELETE` | `/npcs/{npc_id}/loot/{id}` | Delete loot entry |
| `POST` | `/npcs/{npc_id}/scripts` | Add script |
| `PATCH` | `/npcs/{npc_id}/scripts/{id}` | Update script |
| `DELETE` | `/npcs/{npc_id}/scripts/{id}` | Delete script |
| `PUT` | `/npcs/{npc_id}/shop` | Create or replace shop config |
| `DELETE` | `/npcs/{npc_id}/shop` | Delete shop config |

**Resets:**

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/resets?area_id={id}` | List resets for area (ordered by seq) |
| `POST` | `/resets` | Create reset |
| `PATCH` | `/resets/{reset_id}` | Update reset |
| `DELETE` | `/resets/{reset_id}` | Delete reset |

### Validation

The API validates all enum-like fields against configured allowlists:

- `sector_type`: configured via `ALLOWED_SECTOR_TYPES`
- `item_type`: configured via `ALLOWED_ITEM_TYPES`
- `values` JSONB shape: validated per `item_type` against a schema registry in the API
- `flags` arrays: validated against per-entity allowlists (`ALLOWED_ROOM_FLAGS`, `ALLOWED_OBJECT_FLAGS`, `ALLOWED_NPC_FLAGS`, `ALLOWED_EXIT_FLAGS`)
- `wear_slots`: validated against `ALLOWED_WEAR_SLOTS`
- `stat` (on object_affects): validated against `ALLOWED_STATS`
- `trigger_type` (on npc_scripts): validated against `ALLOWED_TRIGGER_TYPES`
- `command` (on resets): validated against the reset command set
- `direction` (on exits): validated against `north, east, south, west, up, down`
- `sex`, `position`: validated against fixed sets

All allowlists are loaded from environment variables at startup. A schema migration is never required to add a new flag, sector type, or item type.

**Allowlist consistency enforcement:** To prevent allowlist drift across instances, the service computes a SHA-256 checksum of all sorted, normalized allowlist values at startup and logs it. The checksum is exposed via `GET /health` in a `config_checksum` field, allowing automated consistency checks across instances. Future improvement: load allowlists from a shared versioned config file rather than per-instance env vars.

---

## Configuration

```
# Database -- app user (mTLS)
DATABASE_URL=postgres://wol_world@db-host:5432/wol_world?sslmode=verify-full&sslrootcert=/path/to/ca.crt&sslcert=/path/to/wol-world.crt&sslkey=/path/to/wol-world.key

# Database -- migration user (mTLS)
MIGRATE_DATABASE_URL=postgres://wol_world_migrate@db-host:5432/wol_world?sslmode=verify-full&sslrootcert=/path/to/ca.crt&sslcert=/path/to/wol-world-migrate.crt&sslkey=/path/to/wol-world-migrate.key

# SPIRE
SPIFFE_ENDPOINT_SOCKET=unix:///var/run/spire/agent.sock

# Rate limiting
RATE_LIMIT_PER_CALLER_RPM=120

# Validation allowlists (comma-separated)
ALLOWED_SECTOR_TYPES=city,field,forest,hills,mountain,water_swim,water_noswim,air,desert,inside,underground
ALLOWED_ITEM_TYPES=weapon,armor,light,scroll,potion,container,key,food,drink,money,furniture,treasure,quest,staff,portal,pill,boat,fountain
ALLOWED_ROOM_FLAGS=dark,regen,no_mob,indoors,no_magic,hot,cold,pk,quiet,private,safe,solitary,pet_shop,no_recall,no_teleport,no_portal,maze
ALLOWED_OBJECT_FLAGS=magic,no_drop,no_remove,bless,anti_good,anti_evil,two_handed,unique,quest_reward,no_save,no_auction,mythic,legendary,rare
ALLOWED_NPC_FLAGS=sentinel,scavenger,aggressive,stay_area,wimpy,undead,pet,train,practice,heal,banker,hunter,boss,no_hunt,solo,ai_dialogue
ALLOWED_EXIT_FLAGS=door,closed,locked,climb,pickproof,smashproof,passproof,nodetect
ALLOWED_WEAR_SLOTS=head,face,neck,shoulders,arms,wrist,hands,finger,hold,about,waist,body,legs,feet,halo,aura,horns,wings,tail,claws,hooves,ear,beak
ALLOWED_STATS=str,dex,int,wis,con,hp,mana,hit_roll,dam_roll,ac,saves
ALLOWED_TRIGGER_TYPES=greet,fight,death,speech,tick,entry,exit,give,bribe,random
```

---

## WOL Server Changes (`wol/`)

### `WorldApiClient.cs`

New file: `wol/Wol.Server/World/WorldApiClient.cs`

```csharp
public sealed class WorldApiClient
{
    private readonly HttpClient _http;

    public WorldApiClient(HttpClient http) => _http = http;

    /// <summary>Loads all areas.</summary>
    public Task<IReadOnlyList<AreaData>> LoadAreasAsync() { ... }

    /// <summary>Loads all rooms (with exits and extra descs) for an area, or all areas if null.</summary>
    public Task<IReadOnlyList<RoomData>> LoadRoomsAsync(long? areaId = null) { ... }

    /// <summary>Loads all object prototypes (with extra descs and affects) for an area, or all.</summary>
    public Task<IReadOnlyList<ObjectPrototype>> LoadObjectsAsync(long? areaId = null) { ... }

    /// <summary>Loads all NPC prototypes (with loot, scripts, shops) for an area, or all.</summary>
    public Task<IReadOnlyList<NpcPrototype>> LoadNpcsAsync(long? areaId = null) { ... }

    /// <summary>Loads all resets for an area, or all.</summary>
    public Task<IReadOnlyList<ResetData>> LoadResetsAsync(long? areaId = null) { ... }
}
```

### World loading at startup

`Program.cs` calls `WorldApiClient` during startup to populate the in-memory world:

1. Load all areas
2. Load all rooms (with exits and extra descs)
3. Load all object prototypes (with extra descs and affects)
4. Load all NPC prototypes (with loot, scripts, shops)
5. Load all resets
6. Execute resets to populate rooms with spawned NPC and object instances

If any bulk load fails, WOL does not start.

### Bulk load consistency

Multiple independent `/bulk/*` calls at startup can ingest mixed-era data if concurrent builder writes occur between calls. To prevent this, the world API serializes all bulk load requests within a single read-only PostgreSQL transaction:

1. The realm calls `POST /bulk/snapshot` to open a `READ ONLY` transaction with `REPEATABLE READ` isolation. The response contains a `snapshot_token` and the complete bulk world data (all areas, rooms, exits, object prototypes, NPC prototypes, resets, shops, scripts, loot tables, extra descriptions, and object affects) in a single response. The transaction is committed immediately after the response is sent.
2. Requests outside of a snapshot are served normally (not in a long-running transaction).

This single-endpoint design ensures all bulk data reflects a single consistent database state without requiring multi-call transaction affinity.

**Snapshot session limits:**
- **Concurrent sessions:** Maximum `MAX_CONCURRENT_SNAPSHOTS` (default: 3) open snapshot requests at any time. Additional requests receive `503 Service Unavailable`. This prevents connection-pool exhaustion from malicious or buggy callers.
- **Per-caller quota:** Each caller SPIFFE ID may hold at most 1 concurrent snapshot request. A second request from the same caller while one is in-flight receives `429 Too Many Requests`.
- **Absolute timeout:** Snapshot queries that exceed `SNAPSHOT_QUERY_TIMEOUT` (default: 60 seconds) are cancelled and the transaction rolled back. This bounds the maximum time a snapshot can pin a DB connection.

**HA considerations:** Because the snapshot is a single request/response (no multi-call affinity), any instance behind a load balancer can serve it. No session stickiness or routing affinity is required. Horizontal scaling is straightforward.

### Cross-domain integrity enforcement

Cross-domain references (e.g., `rooms.area_id`, `resets.room_id`, `npc_loot.object_prototype_id`) use plain BIGINT without foreign key constraints (the referenced tables may be in different domains within the same database). Integrity is enforced at three points:

1. **Write-time validation:** Every write endpoint (`POST`, `PUT`) that accepts a cross-domain reference validates the target exists via a `SELECT 1 FROM <target_table> WHERE id = <ref>` within the same transaction. If the target does not exist, the write is rejected with `422 Unprocessable Entity`.
2. **Delete-time validation:** Every `DELETE` endpoint checks for inbound references before deleting. If references exist, the delete is rejected with `409 Conflict` (caller must remove referencing rows first).
3. **Periodic integrity scanner:** A background task (configurable interval, default 1 hour) scans all cross-domain references and reports orphans. Orphaned references are logged as warnings (not auto-deleted). If any orphans are found, the service sets a health flag that causes `/health` to return `degraded` status, signaling operators to investigate.
4. **Startup gate:** Before the realm loads world data, it calls `GET /integrity` on the world API. If the integrity scanner has found unresolved orphans, this endpoint returns `503` and the realm refuses to start. This prevents loading inconsistent world data.

### SPIRE configuration

WOL requests JWT-SVIDs with audience `spiffe://wol/world` in addition to the existing `spiffe://wol/accounts` and `spiffe://wol/players` audiences. One additional environment variable:

```
WOL_WORLD_API_URL=https://wol-world-host:8443
```

### HttpClient timeout

Bulk loads may transfer significant data. `WorldApiClient`'s `HttpClient` timeout should be higher than the accounts/players clients (30-60 seconds for bulk loads).

---

## Affected Files / Repos

| Repo | File | Change |
|------|------|--------|
| new `wol-world` | `src/Wol.World/Program.cs` | New ASP.NET Core service |
| new `wol-world` | `migrations/001_initial.sql` | Schema (all world tables) |
| new `wol-world` | `tools/Wol.World.Migrate/Program.cs` | Migration runner |
| new `wol-world` | `tests/Wol.World.Tests/` | Area, room, object, NPC, and reset endpoint tests |
| `wol` | `Wol.Server/World/WorldApiClient.cs` | New |
| `wol` | `Wol.Server/World/AreaData.cs` | New record types |
| `wol` | `Wol.Server/World/RoomData.cs` | New record types |
| `wol` | `Wol.Server/World/ObjectPrototype.cs` | New record types |
| `wol` | `Wol.Server/World/NpcPrototype.cs` | New record types |
| `wol` | `Wol.Server/World/ResetData.cs` | New record types |
| `wol` | `Wol.Server/Program.cs` | Register WorldApiClient, call bulk load at startup |
| `aicli` | `CLAUDE.md` | Add `wol-world` to sub-projects list |

---

## Trade-offs

**Pro:**
- All world data persists in a database, not flat files
- Domain boundaries with no cross-domain FKs allow splitting any table group to its own database without schema changes
- TEXT[] arrays for flags are human-readable, queryable, and avoid magic bitmask numbers
- JSONB for type-specific object values is self-documenting and extensible without schema migrations
- All enum-like fields validated by API config, not DB constraints; adding a new item type or flag is a config change, not a migration
- Bulk endpoints serve WOL's startup pattern efficiently
- CRUD endpoints support future builder tools
- Same mTLS/SPIFFE/SPIRE security as all other services
- WOL operates independently once the world is loaded; world API downtime during gameplay has no effect

**Con:**
- WOL startup now requires the world API to be available; a world API outage blocks realm starts
- Bulk loading transfers all world data over the network at startup; for a large world this could be significant (mitigated by: world data is typically megabytes, not gigabytes, and this happens once at startup)
- No cross-domain FK constraints means the API must enforce referential integrity; a bug could leave orphaned references (e.g., a reset referencing a deleted NPC). Mitigated by: CRUD delete endpoints check for references before deleting.
- TEXT[] for flags uses more storage than integer bitmasks, but the readability and queryability benefits outweigh the cost
- JSONB for object values is flexible but not schema-enforced at the DB level; validation is entirely in the API layer
- Single world API serves all realms; if the world definition diverges per realm, this design would need extension (out of scope, all realms share one world)
- NPC scripts are stored as text blobs; no structured scripting language is defined in this proposal (the script format is a future concern)

---

## Security review response

Responses to findings from `proposals/reviews/infrastructure-proposals-security-review-2026-03-25.md` and `proposals/reviews/infrastructure-proposals-review-followup-2026-03-25.md` that are relevant to this proposal.

| Finding | Status | Resolution |
|---------|--------|------------|
| C3 (inconsistent threat boundary) | Acknowledged | A compromised realm can trigger high-impact write operations via the world API (e.g., deleting areas, modifying NPC prototypes). Resolution: introduce role-scoped SPIFFE IDs. Read-only realm identities should not have write access to world data. Write endpoints should require a separate builder/admin SPIFFE ID. |
| M5 (unauthenticated health endpoint) | Acknowledged | `/health` is intentionally unauthenticated. Already scoped to private network via bootstrap script firewall rules (port 8080 from 10.0.0.0/20 only). |
| M6 (cross-domain FK integrity) | Resolved | Cross-domain integrity enforcement section added: write-time validation (transactional existence check), delete-time reference check, periodic integrity scanner (hourly), and startup gate (`GET /integrity` blocks realm loading on orphans). |
| M9 (unconstrained TEXT/JSONB without DB constraints) | Resolved | Added CHECK constraints for known invariants: `level >= 1`, `weight >= 0`, `level_min/max >= 0`, `reset_rate_min > 0`, non-empty text for `sector_type`/`item_type`, and `direction IN (...)` for exits. Enum-like text fields remain unconstrained beyond non-empty checks (validated by API allowlist). JSONB `values` validated by API schema per `item_type`. All write paths must use the same validator library. |
| M10 (rate limiting: no global abuse controls) | Acknowledged | Per-caller rate limiting (120 RPM) is defined but no global ceilings exist. Resolution: add global service-level ceilings and adaptive throttling. The world API handles fewer, larger requests, so anomaly detection should focus on unusual write volume rather than read enumeration. |
| H8 (JWT-SVID replay for write endpoints) | Resolved | Write endpoints require `jti` claim with TTL-windowed deduplication (5-minute cache). Duplicates rejected with `409 Conflict`. Full spec in `infrastructure/identity-and-auth-contract.md`. |
| Followup #3 (world cross-domain integrity) | Resolved | Cross-domain integrity enforcement section added with write-time validation, delete-time checks, periodic scanner, and startup gate. See "Cross-domain integrity enforcement" in the WOL Integration section. |
| Followup #7 (bulk loading consistency) | Resolved | Bulk load consistency section added: all bulk requests serialized within a single `REPEATABLE READ` read-only transaction via `X-Snapshot-Token` header. Ensures consistent point-in-time view across all bulk calls. |
| Followup #8 (config allowlists can drift) | Resolved | Allowlist consistency enforcement added: SHA-256 checksum computed at startup, logged, and exposed via `/health` `config_checksum` field for automated cross-instance comparison. |

Findings addressed in other proposals: C2/M1/M3/M4/M8/M11 (private-ca), C4 (wol-accounts), C5/H3/H4/H5/H7/H9 (wol-gateway), H1/H2/H6 (private-ca/spiffe-spire), M7 (wol-accounts), L1-L3 (wol-gateway and cross-cutting).

---

## Out of Scope

- Runtime instance state (spawned NPC HP, item positions, active room effects)
- Player inventory and equipment
- Quest definitions and quest state tracking
- Clan definitions and membership
- Help and lore entry storage
- Skill and spell definitions
- Per-realm world variants (all realms share one world)
- Builder permission system (who can edit which areas)
- World versioning or change history
- Hot-reload protocol (future proposal; the bulk endpoints support it, but the WOL-side reload mechanism is not defined here)
- Structured scripting language for NPC scripts
- Data migration from acktng area files to wol-world (separate migration task)
