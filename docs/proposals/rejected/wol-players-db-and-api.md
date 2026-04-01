# Proposal: WOL Players Database and API Server

**Status:** Pending
**Date:** 2026-03-25
**Affects:** `wol/`, new `wol-players` repo (API + DB), PostgreSQL, `CLAUDE.md`
**Depends on:** `proposals/active/Infrastructure/wol-accounts-db-and-api.md` -- account session validation, `account_id` identity, mTLS/SPIFFE architecture, and private CA are all defined there

---

## Problem

After the accounts layer (wol-accounts) authenticates a player and issues a session token, WOL has no way to associate that session with a game character. There is no persistent store for character identity: name, race, class, level, or experience. Characters are not yet a concept in any running system. WOL needs a persistent, service-separated character store before any real gameplay can occur.

This proposal defines `wol-players`: the canonical source of truth for character identity. It is the character-layer counterpart to `wol-accounts` (the account/authentication layer).

---

## Scope of This Proposal

`wol-players` stores **character identity and persistent progression state**: who a character is, what race and class they are, and how far they have progressed (level, experience). It does not store volatile in-session state (current HP, position, active buffs) -- that remains WOL's in-memory concern until a future proposal defines a persistence strategy for it.

**What is stored here:**
- Character identity: name, race, class
- Persistent progression: level, experience
- Lifecycle metadata: created_at, last_played_at, deleted_at

**What is not stored here (out of scope):**
- Volatile combat state (HP, mana, position, active effects)
- Inventory and equipment
- Learned skills and spells
- Clan membership
- Character customisation (description, title, etc.)

Each of these is a future proposal.

---

## Deployment Architecture

`wol-players` is an independent repo and runs on a separate machine from WOL. **The players API server and its PostgreSQL database server are separate machines.** The players API is not public-facing -- it runs on a private network and is reachable only from trusted internal services.

Multiple WOL realm servers share the same players API. The players API has no concept of which realm a character is currently connected to -- that state lives in WOL.

The login sequence now has three distinct steps:

1. **Account login** (wol-accounts): the player authenticates with email and password. wol-accounts issues an account session token containing `account_id`.
2. **Character selection** (wol-players): WOL retrieves the account's characters and prompts the player to select one or create a new one. WOL calls `wol-players` to load or create the character record.
3. **Realm session** (WOL): WOL loads the selected character into memory and the game session begins.

The players API is involved only in step 2. Steps 1 and 3 are the concern of their respective layers.

```
Game Clients (telnet / WSS)
    └─ encrypted ──▶ WOL Realm
                          │
                          ├── HTTPS + JWT-SVID ──▶ wol-accounts API  [private network]
                          │                              │
                          │                           Npgsql
                          │                              │
                          │                          PostgreSQL (accounts)
                          │
                          └── HTTPS + JWT-SVID ──▶ wol-players API server  [private network]
                                                         │
                                                    Npgsql + mTLS
                                                         │
                                                     PostgreSQL server (players)  [private network, separate machine]
```

WOL depends on the players API during login. **If the players API is down, character selection and creation are unavailable.** The same reliability requirements as wol-accounts apply:

- **Auto-restart:** `systemd` unit must set `Restart=always` and `RestartSec=2s`.
- **Health monitoring:** `/health` endpoint polled by the infrastructure monitoring stack. Alert immediately on failure; target RTO is less than 2 minutes for a crash/restart scenario.
- **Fast-restart runbook:** DB connectivity check, log inspection, rollback procedure. Target: on-call operator can restore service in less than 5 minutes from alert.
- **HA (future):** Stateless API design (all state in PostgreSQL) makes horizontal scaling straightforward when needed.

The players API is configured entirely via environment variables.

### Private network communication policy

Identical to the accounts proposal: all service-to-service and service-to-database links use mutual TLS (mTLS) with certificates signed by the shared private CA. No private link may use unencrypted transport or one-way TLS. See `wol-accounts-db-and-api.md` and `spiffe-spire-workload-identity.md` for the full architecture. The authorization matrix (which SPIFFE IDs may call which endpoints), SPIFFE ID matching algorithm, JWT-SVID replay protection, and rate limiting policy are defined in `infrastructure/identity-and-auth-contract.md`.

---

## Identity Model

- **`account_id`** -- the account-layer identity. Issued by wol-accounts. Stored in the `characters` table to associate characters with accounts. All requests that reference an `account_id` must include a session token. `wol-players` calls `wol-accounts` (`POST /sessions/validate`) to verify the session belongs to the claimed `account_id` before processing any operation (reads and writes). This prevents a compromised or buggy realm from querying arbitrary account character lists.
- **`char_id`** -- the stable, opaque identifier for a game character. Issued by this service (a BIGSERIAL primary key). Used by WOL and by future services (inventory, skills, etc.) as the canonical character reference.

An account may have up to a configurable maximum number of active (non-deleted) characters (default: `MAX_CHARACTERS_PER_ACCOUNT=5`).

---

## Character Name Policy

Character names are **unique per account**, not globally unique. Two different accounts may each have a character named "Alaric". This avoids name-squatting and removes frustration when a desired name is taken by someone else. Within a single account, no two active characters may share the same name. When a character is deleted, its name becomes available for reuse on that account.

Name format constraints (enforced by the API):
- Alphabetic characters only (A-Z, a-z), no digits or punctuation
- Minimum 3 characters, maximum 15 characters
- Stored and compared case-insensitively (stored as-provided, indexed lowercase)

---

## Security Model

### Per-request authorisation (JWT-SVID) and mTLS

Identical to the accounts proposal. WOL obtains a JWT-SVID from its local SPIRE Agent with audience `spiffe://wol/players` and includes it as `Authorization: Bearer <jwt-svid>` on every request. The players API verifies it against the SPIRE trust bundle. mTLS provides mutual authentication at the transport layer; the JWT-SVID provides a second application-layer check. See `spiffe-spire-workload-identity.md` Section 4.

Both sides obtain their X.509-SVIDs and trust bundles from their local SPIRE Agent. No certificate file paths or CA cert files are stored in environment variables.

### Rate limiting

**Per-caller SPIFFE ID:** the players API enforces a request rate limit per caller SPIFFE ID (default: 60 requests/minute per caller). A compromised realm cannot enumerate all characters faster than this rate allows.

**Per-account character creation:** new character creation per account is limited to a configurable maximum per hour (default: 3 characters/hour/account) to prevent rapid creation-and-deletion cycles.

**`POST /characters/name-available`:** character name lookup is an enumeration primitive. It carries a tighter limit (default: 20 requests/minute per caller SPIFFE ID, configurable via `RATE_LIMIT_NAME_CHECK_PER_CALLER_RPM`). Exceeding this returns `429`. WOL should only call this to give the player feedback during the naming step, not on every keystroke.

Rate limit violations return `429 Too Many Requests`.

**Multi-instance deployment:** Same requirements as wol-accounts: rate limit counters must use a shared store (Redis with sliding-window counters) when multiple instances are deployed. Fails closed on store unavailability. See wol-accounts rate limiting section for details.

### Audit logging

The players API emits structured JSON log lines to stdout for all write operations:

- Character created (account_id, char_id, name, race, class, timestamp)
- Character deleted (account_id, char_id, timestamp)
- Character progress saved (char_id, level, experience, timestamp)

Character names are logged as-is (they are not PII, and their log presence aids support). Account IDs are opaque integers and safe to log.

CORS is explicitly disabled. The players API is a server-to-server API and must not be callable from browsers.

---

## New Repo: `wol-players`

Standalone C#/.NET service and independent git repository. Runs on its own machine on the private network.

### Directory layout

```
wol-players/
  src/
    Wol.Players/
      Program.cs                    # ASP.NET Core minimal API, routes, DI, Kestrel config
      Wol.Players.csproj
  migrations/
    001_initial.sql
  tools/
    Wol.Players.Migrate/
      Program.cs                    # Migration runner (Npgsql, wol_players_migrate user, deployment step)
      Wol.Players.Migrate.csproj
  tests/
    Wol.Players.Tests/
      CharacterTests.cs
      Wol.Players.Tests.csproj
  .env.example
  README.md
```

### Database users

Two PostgreSQL users are required:

| User | Permissions | Purpose |
|------|-------------|---------|
| `wol_players_migrate` | `CREATE TABLE`, `CREATE INDEX`, `GRANT`; ownership of all wol_players tables; full access to `schema_migrations`; authenticates via client certificate (mTLS) | Runs migrations and issues GRANTs as a deployment step; not used by the running API |
| `wol_players` | `SELECT/INSERT/UPDATE/DELETE` on `characters` table and its sequences; no access to `schema_migrations`; authenticates via client certificate (mTLS) | Used by the running API server; no DDL or migration permissions |

The database is named `wol_players` and runs on a dedicated PostgreSQL server, separate from the players API server and separate from the accounts database server. The API connects via `DATABASE_URL`.

### Schema migration process

Identical to the accounts proposal. Migrations are a **deployment step**, not part of API startup:

```
dotnet run --project tools/Wol.Players.Migrate
```

using the `wol_players_migrate` database credentials. The tool creates the `schema_migrations` tracking table if absent, then runs each `.sql` file from `migrations/` in filename order that is not already recorded. A failed migration aborts the deployment.

`wol_players_migrate` credentials must not be stored persistently on the API server disk. They are injected at deploy time and discarded after the migration run.

```sql
-- Bootstrap (run by migration tool before the migration loop, always)
CREATE TABLE IF NOT EXISTS schema_migrations (
    filename   TEXT        PRIMARY KEY,
    applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

### Database schema

```sql
-- migrations/001_initial.sql

CREATE TABLE characters (
    id               BIGSERIAL    PRIMARY KEY,
    account_id       BIGINT       NOT NULL,           -- from wol-accounts; no DB-level FK (separate service)
    name             TEXT         NOT NULL,
    name_lower       TEXT         NOT NULL,            -- lowercase of name; used for per-account uniqueness
    race             TEXT         NOT NULL,
    character_class  TEXT         NOT NULL,
    level            INT          NOT NULL DEFAULT 1   CHECK (level >= 1),
    experience       BIGINT       NOT NULL DEFAULT 0   CHECK (experience >= 0),
    created_at       TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    last_played_at   TIMESTAMPTZ,
    deleted_at       TIMESTAMPTZ,                      -- NULL means active; non-NULL means soft-deleted
    CONSTRAINT name_length CHECK (length(name) BETWEEN 3 AND 15),
    CONSTRAINT name_alpha CHECK (name ~ '^[A-Za-z]+$'),
    CONSTRAINT race_not_empty CHECK (length(race) > 0),
    CONSTRAINT class_not_empty CHECK (length(character_class) > 0)
);

-- Names are unique per account among active characters; deleted names are reusable
CREATE UNIQUE INDEX characters_account_name_active_uidx
    ON characters (account_id, name_lower)
    WHERE deleted_at IS NULL;

-- Index for listing a player's active characters by account
CREATE INDEX characters_account_id_active_idx ON characters (account_id)
    WHERE deleted_at IS NULL;

-- Grant app-user permissions (run by wol_players_migrate after table creation)
GRANT SELECT, INSERT, UPDATE, DELETE ON characters TO wol_players;
GRANT USAGE, SELECT ON SEQUENCE characters_id_seq TO wol_players;
```

**`account_id` is not a foreign key:** the accounts database is a separate service. `wol-players` validates account ownership on all operations (reads and writes) by calling `wol-accounts` (`POST /sessions/validate`) with the caller-provided session token.

**Name uniqueness:** `name_lower` stores `name.strip().lower()`. `name` stores the player's original capitalisation for display. The partial unique index `characters_account_name_active_uidx` ensures no two active characters on the same account share a name (case-insensitive). Deleting a character frees the name for reuse. Different accounts may freely use the same name.

**Race and class as TEXT:** `race` and `character_class` are stored as unconstrained TEXT. Validation against the allowed set is enforced in the API layer, not the DB. This avoids a schema migration every time a race or class is added or removed.

**No per-account character limit in the DB:** the limit (`MAX_CHARACTERS_PER_ACCOUNT`) is enforced at the API layer with a `SELECT COUNT(*)` on active characters before insertion.

### API endpoints

All endpoints except `GET /health` require a valid JWT-SVID bearer token (verified against the SPIRE trust bundle) and a valid mTLS client certificate.

| Method   | Path                          | Description |
|----------|-------------------------------|-------------|
| `GET`    | `/health`                     | Liveness check -- unauthenticated, by design |
| `GET`    | `/characters`                 | List active characters for an account |
| `POST`   | `/characters`                 | Create a new character |
| `GET`    | `/characters/{char_id}`       | Get a character by ID |
| `PATCH`  | `/characters/{char_id}`       | Save character progress (level, experience, last_played_at) |
| `DELETE` | `/characters/{char_id}`       | Soft-delete a character |
| `POST`   | `/characters/name-available`  | Check if a character name is available |

`char_id` and `account_id` are opaque integers, not PII or credentials, so they may appear in URL paths and query parameters. Only the character name check endpoint uses a POST body to keep consistent with the pattern of keeping potentially-logged values out of query strings where practical, though name availability is not a security-sensitive operation.

---

#### `GET /health`

Unauthenticated. Intended for internal monitoring tools only.

Responses:
- `200 OK` `{ "status": "ok" }`
- `503 Service Unavailable` `{ "status": "db_unavailable" }`

---

#### `GET /characters?account_id={id}`

Returns all active (non-deleted) characters for the given account. WOL calls this immediately after successful account login to populate the character selection screen.

Query parameter: `account_id` (required, integer).

Response:
```json
{
  "characters": [
    {
      "char_id": 7,
      "name": "Alaric",
      "race": "human",
      "character_class": "knight",
      "level": 12,
      "experience": 48500,
      "created_at": "2026-01-10T14:22:00Z",
      "last_played_at": "2026-03-24T20:15:00Z"
    }
  ]
}
```

An empty `characters` array means the account has no characters yet -- WOL should proceed directly to character creation.

Responses:
- `200 OK`
- `422 Unprocessable Entity` -- missing or invalid `account_id`

---

#### `POST /characters`

Creates a new character. WOL calls this after the player completes the character creation flow.

Request:
```json
{
  "account_id": 42,
  "name": "Alaric",
  "race": "human",
  "character_class": "knight"
}
```

Validation:
- `account_id`: required positive integer
- `name`: 3-15 alphabetic characters; normalised to `strip()` before validation; case-insensitive uniqueness check via `name_lower`
- `race`: must be in the configured `ALLOWED_RACES` set
- `character_class`: must be in the configured `ALLOWED_CLASSES` set
- Active character count for the account must be below `MAX_CHARACTERS_PER_ACCOUNT`

The API checks name availability (among active characters on the account) and the account character limit atomically. If the name is already used by an active character on the same account, `409 Conflict` is returned.

New characters start at level 1, experience 0.

Responses:
- `201 Created`
  ```json
  {
    "char_id": 7,
    "name": "Alaric",
    "race": "human",
    "character_class": "knight",
    "level": 1,
    "experience": 0,
    "created_at": "2026-03-25T10:00:00Z",
    "last_played_at": null
  }
  ```
- `409 Conflict` -- name already used by an active character on this account
- `409 Conflict` -- account has reached `MAX_CHARACTERS_PER_ACCOUNT`
- `422 Unprocessable Entity` -- validation failure (name format, unknown race, unknown class)
- `429 Too Many Requests` -- character creation rate limit exceeded

---

#### `GET /characters/{char_id}`

Returns the character record for the given ID. WOL calls this to load a selected character into the game session, and may call it again on reconnect to reload character state.

Responses:
- `200 OK`
  ```json
  {
    "char_id": 7,
    "account_id": 42,
    "name": "Alaric",
    "race": "human",
    "character_class": "knight",
    "level": 12,
    "experience": 48500,
    "created_at": "2026-01-10T14:22:00Z",
    "last_played_at": "2026-03-24T20:15:00Z"
  }
  ```
- `404 Not Found` -- char_id does not exist or is soft-deleted

`account_id` is included in the response so WOL can verify the character belongs to the authenticated player (the `account_id` from the accounts session must match).

---

#### `PATCH /characters/{char_id}`

Saves character progress. WOL calls this on clean logout and at periodic save intervals during play to persist level and experience gains. Only the fields listed below may be updated by this endpoint.

Request (all fields optional; only provided fields are updated):
```json
{
  "level": 13,
  "experience": 52000,
  "last_played_at": "2026-03-25T21:30:00Z"
}
```

Validation:
- `level`: positive integer; must not be less than the character's current level (levels do not decrease)
- `experience`: non-negative integer
- `last_played_at`: must not be in the future; if omitted, the API sets it to `NOW()`

Responses:
- `200 OK` -- updated character record (same shape as `GET /characters/{char_id}`)
- `404 Not Found` -- char_id does not exist or is soft-deleted
- `422 Unprocessable Entity` -- validation failure

---

#### `DELETE /characters/{char_id}`

Soft-deletes a character by setting `deleted_at = NOW()`. The character record is retained for administrative and audit purposes. The name is freed for reuse on the same account (the partial unique index only covers active characters).

The players API validates account ownership server-side: the request must include `account_id` in the body, and the API verifies it matches the character's stored `account_id`. The API also calls `POST /sessions/validate` on wol-accounts to verify the session belongs to the claimed account (same pattern as POST and PATCH).

Request:
```json
{ "account_id": 42 }
```

Responses:
- `204 No Content`
- `403 Forbidden` -- account_id does not match the character's owner
- `404 Not Found` -- char_id does not exist or is already deleted

---

#### `POST /characters/name-available`

Checks whether a character name is available for the given account. Used by WOL to provide player feedback during character creation before the full `POST /characters` call.

Request:
```json
{ "account_id": 42, "name": "Alaric" }
```

The API normalises the name (strip, lowercase) and checks the `name_lower` column for active characters on the given `account_id`.

Responses:
- `200 OK` `{ "available": true | false }`
- `429 Too Many Requests` -- rate limit exceeded

---

### Configuration

```
# Database -- app user (mTLS: sslmode=verify-full + step-ca-managed client cert)
DATABASE_URL=postgres://wol_players@db-host:5432/wol_players?sslmode=verify-full&sslrootcert=/path/to/ca.crt&sslcert=/path/to/wol-players.crt&sslkey=/path/to/wol-players.key

# Database -- migration user (same mTLS requirements)
MIGRATE_DATABASE_URL=postgres://wol_players_migrate@db-host:5432/wol_players?sslmode=verify-full&sslrootcert=/path/to/ca.crt&sslcert=/path/to/wol-players-migrate.crt&sslkey=/path/to/wol-players-migrate.key

# SPIRE -- Workload API socket
SPIFFE_ENDPOINT_SOCKET=unix:///var/run/spire/agent.sock

# Character limits
MAX_CHARACTERS_PER_ACCOUNT=5
MAX_CHARACTER_CREATION_PER_ACCOUNT_PER_HOUR=3

# Allowed races and classes (comma-separated; validated at startup)
ALLOWED_RACES=human,khenari,khephari,deltari,rivennid,serathi,umbral
ALLOWED_CLASSES=assassin,brawler,cipher,cleric,crusader,druid,egomancer,grand_magi,hierophant,kinetimancer,knight,magi,martial_artist,monk,necromancer,nightblade,paladin,priest,psionicist,pugilist,sorcerer,swordsman,templar,thornwarden,warlock,warden,wildspeaker,wizard

# Rate limiting
RATE_LIMIT_PER_CALLER_RPM=60
RATE_LIMIT_NAME_CHECK_PER_CALLER_RPM=20
```

`ALLOWED_RACES` and `ALLOWED_CLASSES` are validated at API startup -- the process exits if either is empty or malformed. A schema migration is not required to add or remove a race or class; a config change and restart are sufficient.

**Allowlist consistency enforcement:** To prevent allowlist drift across instances, the service computes a SHA-256 checksum of the sorted, normalized allowlist values at startup and logs it. If multiple instances are running, an operator (or monitoring) can compare checksums to detect divergence. The allowlist values and checksum are also exposed via `GET /health` in a `config_checksum` field, allowing automated consistency checks. Future improvement: load allowlists from a shared versioned config file (deployed alongside the service binary) rather than per-instance env vars.

Note: `SSL_CERT`, `SSL_KEY`, and `SSL_CA_CERT` are not used. The API obtains its X.509-SVID and trust bundle from the SPIRE Agent via `SPIFFE_ENDPOINT_SOCKET`. PostgreSQL client cert paths (in `DATABASE_URL`) are managed by step-ca's renewal daemon. See `private-ca-and-secret-management.md` and `spiffe-spire-workload-identity.md` for details.

---

## WOL Server Changes (`wol/`)

### Character selection flow

After successful account login (state: `LoggedIn` in `LoginStateMachine`), WOL hands off to a new `CharacterSelectionStateMachine`. This state machine:

1. Calls `GET /characters?account_id={id}` on the players API.
2. If the account has characters, presents a numbered list and prompts the player to select one or create a new one.
3. On selection, calls `GET /characters/{char_id}` to load the record, verifies `account_id` matches, and hands off to the game session.
4. On new character creation, collects name, race, and class from the player (with `POST /characters/name-available` feedback during naming), then calls `POST /characters`.

For WebSocket clients, this flow is driven by JSON messages with an `action` field (`"list_characters"`, `"select_character"`, `"create_character"`).

### `CharacterApiClient.cs`

New file: `wol/Wol.Server/Character/CharacterApiClient.cs`

```csharp
public sealed class CharacterApiClient
{
    private readonly HttpClient _http;

    public CharacterApiClient(HttpClient http) => _http = http;

    /// <summary>Returns active characters for the given account. Empty list means no characters yet.</summary>
    public Task<IReadOnlyList<CharacterInfo>> ListAsync(long accountId) { ... }

    /// <summary>Creates a new character. Returns null on 409 Conflict (name taken or limit reached). Throws on other errors.</summary>
    public Task<CharacterInfo?> CreateAsync(long accountId, string name, string race, string characterClass) { ... }

    /// <summary>Loads a character by ID. Returns null if not found or deleted.</summary>
    public Task<CharacterInfo?> GetAsync(long charId) { ... }

    /// <summary>
    /// Saves character progress. Called on logout and at periodic intervals during play.
    /// level and experience may be null to leave them unchanged; lastPlayedAt defaults to now if null.
    /// </summary>
    public Task SaveAsync(long charId, int? level, long? experience, DateTimeOffset? lastPlayedAt = null) { ... }

    /// <summary>Soft-deletes a character. Called only after WOL has verified account ownership.</summary>
    public Task DeleteAsync(long charId) { ... }

    /// <summary>Returns true if the name is available for the given account.</summary>
    public Task<bool> IsNameAvailableAsync(long accountId, string name) { ... }
}
```

`CharacterInfo` is a simple record mirroring the API response fields.

### `IGameConnection` -- character field

`IGameConnection` is extended with a `CharacterId` property alongside the existing `SessionToken`:

```csharp
public interface IGameConnection
{
    ConnectionType ConnectionType { get; }
    string? SessionToken { get; set; }
    long? CharacterId { get; set; }      // set after character selection
    Task SendAsync(string text);
    Task CloseAsync();
}
```

### SPIRE configuration

WOL requests JWT-SVIDs with two audiences: `spiffe://wol/accounts` (for accounts API calls) and `spiffe://wol/players` (for players API calls). Both are fetched from the local SPIRE Agent. One additional environment variable:

```
WOL_PLAYERS_API_URL=https://wol-players-host:8443
```

### HttpClient timeout

`CharacterApiClient`'s `HttpClient` must be configured with a timeout (5-10 seconds). On timeout, the character selection flow informs the player of a server error and closes the connection.

---

## Affected Files / Repos

| Repo | File | Change |
|------|------|--------|
| new `wol-players` | `src/Wol.Players/Program.cs` | New ASP.NET Core service |
| new `wol-players` | `migrations/001_initial.sql` | Schema (characters table) |
| new `wol-players` | `tools/Wol.Players.Migrate/Program.cs` | Migration runner (wol_players_migrate user, deployment step) |
| new `wol-players` | `tests/Wol.Players.Tests/` | Integration tests |
| `wol` | `Wol.Server/Character/CharacterApiClient.cs` | New |
| `wol` | `Wol.Server/Character/CharacterSelectionStateMachine.cs` | New |
| `wol` | `Wol.Server/Network/IGameConnection.cs` | Add `CharacterId` property |
| `wol` | `Wol.Server/Network/TelnetConnection.cs` | Implement `CharacterId` |
| `wol` | `Wol.Server/Network/WebSocketConnection.cs` | Implement `CharacterId` |
| `wol` | `Wol.Server/Auth/LoginStateMachine.cs` | Hand off to `CharacterSelectionStateMachine` after login |
| `wol` | `Wol.Server/Program.cs` | Register second `HttpClient` for players API; inject `CharacterApiClient` |
| `aicli` | `CLAUDE.md` | Add `wol-players` to sub-projects list |

---

## Trade-offs

**Pro:**
- Character identity persists across restarts
- `account_id` is not a DB-level FK -- players service remains deployable without a running accounts service
- Race and class validation in the API layer -- no schema migration for game design changes
- Soft delete preserves character records for audit; deleting a character frees the name for reuse on that account
- Character name uniqueness is enforced per account among active (non-deleted) characters
- `PATCH` for progress saves is idempotent and safe to call multiple times
- `account_id` returned in `GET /characters/{char_id}` -- WOL can verify ownership without a separate call
- All wol-accounts security patterns inherited: mTLS, JWT-SVID, per-caller rate limiting, structured audit logging

**Con:**
- WOL now has two hard dependencies at login time (accounts API and players API); if either is down, login is blocked
- Character selection adds one or more API round-trips to the login flow (acceptable for a login path, not a hot path)
- No DB-level FK from `characters.account_id` to `accounts.id` -- application must enforce ownership. Write operations call `POST /sessions/validate` on wol-accounts on every request (no caching). Read operations (`GET /characters`) trust the caller-supplied `account_id` (WOL has already validated the session). This means a revoked session is blocked on the next write within seconds, while reads may continue until WOL's 5-minute heartbeat detects the revocation.
- Soft-deleted character records are retained for audit but their names are freed for reuse on the same account. If audit requirements change, a hard-delete policy or archival strategy would need a separate proposal.
- `ALLOWED_RACES` and `ALLOWED_CLASSES` require a service restart to update (no hot-reload). This is acceptable -- game design changes to available races/classes should go through a deploy.

---

## Security review response

Responses to findings from `proposals/reviews/infrastructure-proposals-security-review-2026-03-25.md` and `proposals/reviews/infrastructure-proposals-review-followup-2026-03-25.md` that are relevant to this proposal.

| Finding | Status | Resolution |
|---------|--------|------------|
| C1 (account_id trust without cryptographic proof) | Resolved -- pre-implementation blocker | `wol-players` calls `wol-accounts` (`POST /sessions/validate`) for server-side session validation on **all operations** (reads and writes). The caller passes the session token alongside `account_id`; `wol-players` verifies the session is valid and belongs to that account before proceeding. Validation results are cached briefly (TTL matching JWT-SVID lifetime) to amortize the round-trip cost on read-heavy flows like character selection. |
| C3 (inconsistent threat boundary) | Acknowledged | See wol-accounts response. A compromised realm can operate on character data outside its intended session scope. Resolution requires scoped SPIFFE IDs per realm and per-role authorization matrices, plus signed user-context propagation. |
| H8 (JWT-SVID replay for write endpoints) | Resolved | Write endpoints require `jti` claim with TTL-windowed deduplication (5-minute cache). Duplicates rejected with `409 Conflict`. Full spec in `infrastructure/identity-and-auth-contract.md`. |
| M5 (unauthenticated health endpoint) | Acknowledged | `/health` is intentionally unauthenticated. Already scoped to private network via bootstrap script firewall rules (port 8080 from 10.0.0.0/20 only). |
| M9 (unconstrained TEXT fields without DB safeguards) | Resolved | Added CHECK constraints for known invariants: `level >= 1`, `experience >= 0`, name length/alpha, non-empty race/class. Race and class remain unconstrained TEXT (validated by API allowlist) to avoid schema migrations on game design changes. All write paths must use the same validator library. |
| M10 (rate limiting: no global abuse controls) | Acknowledged | Per-caller rate limiting is defined but no global ceilings exist. Resolution: add global service-level ceilings, adaptive throttling, and anomaly detection (cross-caller correlated spikes on `name-available`). Define emergency limits toggleable during incidents. |
| Followup #8 (config allowlists can drift across instances) | Resolved | Allowlist consistency enforcement added: SHA-256 checksum computed at startup, logged, and exposed via `/health` `config_checksum` field for automated cross-instance comparison. |

Findings addressed in other proposals: C2/M1/M3/M4/M8/M11 (private-ca), C4 (wol-accounts), C5/H3/H4/H5/H7/H9 (wol-gateway), H1/H2/H6 (private-ca/spiffe-spire), M7 (wol-accounts), L1-L3 (wol-gateway and cross-cutting).

---

## Out of Scope

- Volatile in-session state (HP, mana, position, active effects) -- WOL's in-memory concern; future persistence proposal
- Inventory and equipment
- Learned skills and spells
- Character customisation (title, description, etc.)
- Clan membership
- Admin API for character management (name release, forced deletion, etc.)
- Character transfer between accounts
- Password-protected character deletion confirmation flow (future UX proposal)
- Global character name uniqueness (names are per-account in this proposal)
- Character appearance or stat allocation at creation (deferred -- requires game design spec)
- Per-account character slot purchasing or expansion
