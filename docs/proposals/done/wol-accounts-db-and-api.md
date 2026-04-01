# Proposal: WOL Accounts Database and API Server

**Status:** Pending
**Date:** 2026-03-24
**Affects:** `wol/`, new `wol-accounts` repo (API + DB), PostgreSQL, `CLAUDE.md`
**Depends on:** `proposals/active/Infrastructure/private-ca-and-secret-management.md` (offline root CA, step-ca for DB certs, cert profiles), `proposals/active/Infrastructure/spiffe-spire-workload-identity.md` (service-to-service mTLS via X.509-SVIDs, JWT-SVID bearer tokens)

---

## Problem

`AccountStore` in `wol/Wol.Server/Auth/AccountStore.cs` is an in-memory stub -- its own docstring says "Backed by a real database in a follow-on proposal." All accounts are lost on server restart. WOL needs a persistent, service-separated account store before it can be used in any real capacity.

---

## Deployment Architecture

`wol-accounts` is an independent repo and runs on a separate machine from WOL. The accounts API and its PostgreSQL database may also run on separate machines from each other if needed. **The accounts API is not public-facing** -- it runs on a private network and is reachable only from trusted internal services. No public DNS record exists for the accounts API.

Multiple WOL realm servers share the same accounts API. The accounts API handles **account-level authentication only** -- it has no concept of which realm a player is connected to.

The login sequence has two distinct steps:

1. **Account login** -- the player authenticates with email and password. wol-accounts verifies credentials and issues an account session token. There is exactly one active account session per account at all times.
2. **Realm login** -- the player presents their account session token to a WOL realm. WOL validates the token via `POST /sessions/validate` (token in request body, never in URL path), then manages its own realm-level state (which character is loaded, which zone they're in, etc.). A realm login cannot occur without a valid prior account login.

The accounts API is only involved in step 1. Step 2 is WOL's concern.

```
Game Clients (telnet / WSS)          Game Clients (telnet / WSS)
    └─ encrypted ──▶ WOL Realm A ──┐     └─ encrypted ──▶ WOL Realm B ──┐
                                    └──── HTTPS + bearer token ───────────┤
                                                                           ▼
                                                              wol-accounts API  [private network]
                                                                           │
                                                                      Npgsql
                                                                           │
                                                                      PostgreSQL [private network]
```

WOL depends on the accounts API being available. **If the accounts API is down, all WOL realms are down** -- there is no graceful degradation. This is an explicit reliability gap; the following mitigations are required:

- **Auto-restart:** The accounts API `systemd` unit must set `Restart=always` and `RestartSec=2s`. The vast majority of outages (OOM, crash, bad deploy) are recoverable within seconds automatically.
- **Health monitoring:** The `/health` endpoint is polled by the infrastructure monitoring stack. Alert immediately when it fails -- target RTO from page to service-restored is **< 2 minutes** for a crash/restart scenario.
- **Fast-restart runbook:** A runbook for manual recovery covers: DB connectivity check, log inspection, rollback procedure. Target: on-call operator can restore service in < 5 minutes from alert.
- **HA (future):** Running multiple accounts API instances behind a load balancer is out of scope for this proposal but is the correct long-term remedy for this reliability gap. The stateless design of the API (all state in PostgreSQL) makes horizontal scaling straightforward when needed.

The accounts API is configured entirely via environment variables, making it straightforward to point at a local or remote PostgreSQL instance with no code changes.

### Private network communication policy

**All private links between servers use mutual TLS (mTLS).** This is a global architectural requirement, not specific to any single link. Every service-to-service connection -- WOL → accounts API, accounts API → PostgreSQL, and any future inter-service links -- must use mTLS with certificates signed by the shared private CA. No private link may use unencrypted transport or one-way TLS.

---

## Identity Model

This service manages **authentication and account identity**. It has no knowledge of game characters.

- **`account_id`** -- stable, opaque identifier for a player's account. Used by all account-layer operations (authentication, session management, account settings). Returned in session validation responses and used to link a player to their characters.
- **`account_name`** -- the player's display name. Globally unique (case-insensitive). This is the human-readable identity shown to other players and used in-game where an account-level name is needed (e.g., chat, friends lists, administrative logs). Not used for authentication; email remains the login credential.
- **`char_id`** -- stable, opaque in-game identity. Belongs to the game/character layer, defined in a future proposal. Not stored or managed by this service.

An account may have one or more characters. The mapping from `account_id` to `char_id` is the responsibility of a separate character service, not this one.

### Account name policy

Account names are **globally unique** and **case-insensitive**. The original capitalisation is preserved for display; a lowercase copy is stored for uniqueness enforcement.

Name format constraints (enforced by the API):
- Alphabetic characters only (A-Z, a-z), no digits or punctuation
- Minimum 3 characters, maximum 15 characters
- Stored as-provided; compared and indexed via a lowercase copy (`name_lower`)

---

## Security Model

### Telnet limitation

Telnet has no transport encryption. A player's password travels in plaintext from their client to WOL across the network. This is a fundamental limitation of the protocol and cannot be mitigated at the WOL level. The cleartext exposure during transit is acknowledged and accepted. WOL forwards the plaintext to the accounts API immediately over mTLS -- it does not retain or store the password beyond this call.

### Password hashing

**All BCrypt operations are performed inside the accounts API. WOL transmits plaintext passwords to the accounts API over mTLS -- they never touch disk and are never stored by WOL.**

The accounts API is the sole authority for all BCrypt operations:
- **Registration:** `BCrypt.Net.BCrypt.EnhancedHashPassword(password, workFactor: 12)` -- hash stored, plaintext discarded
- **Authentication:** `BCrypt.Net.BCrypt.EnhancedVerify(plaintext, stored_hash)` -- run atomically with failure counting inside `POST /auth/login`

WOL reads the password from the player connection and immediately passes it to the accounts API. It does not hash, store, or re-use the password.

**Why plaintext to the accounts API?** The previous design had WOL fetch the stored BCrypt hash and verify locally. This gave any compromised WOL realm the ability to bulk-request every account's stored hash via the password-hash endpoint and run offline cracking attacks against them. Moving verification server-side means the accounts API never exposes stored hashes to any caller -- a compromised realm can only attempt logins at the API's enforced rate. The mTLS link between WOL and the accounts API provides mutual authentication and encryption equivalent to a local inter-process call.

WOL enforces TLS for WebSocket connections -- plain WS upgrades are rejected, and the server refuses to start without a valid TLS certificate.

The BCrypt work factor is explicitly set to **12** in accounts API configuration. BCrypt at work factor 12 takes ~300ms per operation; the accounts API runs BCrypt on a background thread via `Task.Run` to avoid blocking the request pipeline. WOL does not use BCrypt.Net-Next and does not take the hashing cost.

**BCrypt thread pool exhaustion:** Concurrent BCrypt operations tie up thread pool threads. The API enforces a configurable maximum number of in-flight BCrypt operations via a `SemaphoreSlim` (default: `BCRYPT_MAX_CONCURRENT=8`). Requests that cannot acquire the semaphore immediately receive `429 Too Many Requests`. This prevents a flood of login attempts from exhausting the thread pool and degrading all API operations.

**Per-source BCrypt pool starvation:** A single source can monopolise the entire BCrypt pool by sending `BCRYPT_MAX_CONCURRENT` concurrent requests. To prevent this, the ingress layer (reverse proxy / load balancer) must enforce a per-source-IP concurrent connection limit specifically for `POST /auth/login` -- no single IP should hold more than 2 concurrent in-flight login requests. This is an ingress concern, not enforced in the API itself, because the API cannot reliably identify the originating IP behind a proxy.

### Email normalisation

All email addresses are normalised to lowercase by the API before any database read or write. This ensures case-insensitive behaviour regardless of how the player typed their address.

**WOL must also normalise emails to lowercase before using them for any purpose** -- logging, UI display, error messages, or sending to the API. If WOL logs `User@Example.com` while the DB stores `user@example.com`, support investigations become needlessly difficult (identity fragmentation across logs). The API normalisation is a correctness safety net, not a substitute for normalising at the edge. Rule: `email.strip().lower()` at the point WOL reads the address from the player, before any further use.

### Session token security

Session tokens are generated using `secrets.token_urlsafe(32)` (256 bits of cryptographic randomness). The plaintext token is returned to WOL exactly once at creation. **Only a SHA-256 hash of the token is stored in the database.** If the database is compromised, stored token hashes cannot be directly replayed -- the attacker would need to reverse SHA-256 to obtain the usable token. WOL holds the plaintext token in process memory for the lifetime of the connection.

The session token exists in plaintext in WOL's process memory for the duration of the connection. This is an inherent and accepted risk of in-memory session state -- a process memory dump would expose active tokens.

When WOL restarts, all in-memory session tokens are lost. Players must re-authenticate. Orphaned tokens in the database expire naturally.

### One session per account

**An account may hold exactly one active account session at a time.** `POST /auth/login` uses an `INSERT ... ON CONFLICT (account_id) DO UPDATE` upsert, atomically replacing any existing session. This is enforced at the DB level by the `UNIQUE` constraint on `account_id` in the `sessions` table.

A new account login -- regardless of which realm or client initiates it -- invalidates the previous account session. Any realm holding the old token will receive `404` on the next `POST /sessions/validate` call and must disconnect the player.

**Session-churn DoS:** An attacker with valid credentials can log in repeatedly to kick the legitimate player's session. Mitigation: the per-account session creation rate limit (see Rate limiting above) caps how frequently this can be done. Full protection requires account takeover prevention (strong passwords, future MFA).

### Session expiry and active gameplay

Session tokens expire after a configurable TTL (default **2 hours**). An **inactivity timeout** applies separately: a session whose `last_seen_at` is older than the inactivity threshold (default 30 minutes) is treated as expired at validation time even if the TTL has not elapsed.

**Periodic heartbeat revalidation:** WOL calls `POST /sessions/validate` at a configurable interval (default: every 5 minutes) during active gameplay. If the response is `404` (session expired, revoked, or account locked), WOL disconnects the player immediately. This bounds the window in which a revoked account or stolen token can remain active in-game to the heartbeat interval.

Token expiry is enforced at two additional points:
- When a client presents a saved token to resume a previous session (WebSocket reconnect flow).
- When another service calls `POST /sessions/validate` to verify a player's identity.

On connection drop and reconnect, the player must re-authenticate if their token has expired.

**WOL is responsible for calling `POST /sessions/revoke`** on clean connection close, on any disconnection detection, and on idle timeout. Revoke failures are logged but do not throw -- the session expires naturally. The accounts API provides the endpoint; when WOL calls it is WOL's operational concern.

### TLS certificate rotation

**WOL must hot-reload mTLS certificates without restarting.** The private-ca proposal specifies 24-hour certificate lifetimes; a restart on each renewal would disconnect all active players every day.

.NET's `HttpClient` and `SslStream` cache `X509Certificate2` objects in memory. Changing the cert file on disk does not affect the running process without explicit handling. WOL must implement one of:

- A `FileSystemWatcher` on the cert file paths that rebuilds the `HttpClientHandler` (with the new cert loaded from disk) and atomically replaces the `HttpClient` instance when a change is detected. New connections use the new handler immediately; existing in-flight requests on the old handler complete without disruption.
- Periodic handler rotation via `IHttpClientFactory` with `HandlerLifetime` set to a value shorter than the cert lifetime (e.g., 1 hour). A new `HttpClientHandler` is constructed from disk on each rotation cycle; the old handler continues serving in-flight requests until it is garbage-collected.

This is a WOL implementation concern, addressed when `AccountApiClient` is implemented. The requirement is stated here because the wol-accounts cert lifetime (24 hours) drives the need for it.

### Account lockout

After 5 consecutive failed login attempts, an account is locked for 15 minutes. Thresholds are configurable via environment variables. **Failure counting is performed entirely inside the accounts API** -- WOL never reports failures separately. `POST /auth/login` atomically: verifies the password, increments the failure counter on mismatch, triggers lockout if the threshold is reached, and creates/upserts the session on success. A buggy or malicious realm cannot bypass lockout by omitting a failure-report call.

**When lockout is triggered, all active sessions for that account are immediately invalidated** in the same database transaction. This ensures an attacker who obtained a valid session token before the lockout cannot continue playing.

The `failed_login_attempts` counter is reset to zero on successful login.

### Rate limiting

Rate limiting operates at two levels:

**Per-account:** the lockout mechanism (above) is the primary per-account rate limit. In addition, new session creation per account is limited to a configurable maximum per hour (default: 10 successful logins/hour/account) to prevent the session-churn DoS described below.

**Per-caller SPIFFE ID:** the accounts API enforces a request rate limit per caller SPIFFE ID (e.g., 60 requests/minute per caller). This limits the blast radius of a compromised realm -- it cannot enumerate or spray credentials faster than the rate allows.

**Per-endpoint tighter limits:** `POST /accounts/exists` is a pure enumeration primitive -- it reveals whether an email is registered without requiring a password. It carries a tighter limit than the global per-caller rate (default: 10 requests/minute per caller SPIFFE ID, configurable via `RATE_LIMIT_EXISTS_PER_CALLER_RPM`). Violations return `429`. WOL should only call this endpoint at registration time to give the player feedback before the registration form is submitted; it must not be called on every login attempt.

**Per-source-IP:** rate limiting by source IP is left to the network ingress layer (firewall, load balancer, or reverse proxy). The accounts API is private-network only and its callers are WOL realm servers with known IPs -- IP-level rate limiting at the application layer is not the primary mechanism here.

Rate limit violations return `429 Too Many Requests`.

**Multi-instance deployment:** Rate limit counters are process-local by default (single-instance deployment). When multiple API instances are deployed behind a load balancer, counters must use a shared store (Redis with sliding-window counters) so that the effective attacker budget does not scale with replica count. If the shared store is unavailable, rate limiting fails closed (requests are rejected with `503`) rather than fail-open. The shared store requirement is a prerequisite for any multi-instance deployment.

### Audit logging

The accounts API emits structured JSON log lines to stdout for all security-relevant events. **Email addresses are sanitized before logging** (control characters and newlines stripped, truncated to a safe length) to prevent log injection attacks.

Events logged:
- Account created (sanitized email, timestamp)
- Login attempt failed (sanitized email, timestamp)
- Account locked (sanitized email, timestamp, attempt count)
- Session created (account ID, timestamp) -- email not logged here
- Session deleted (token hash prefix, timestamp)

### Per-request authorization (JWT-SVID)

> **Normative source:** The authorization matrix (which SPIFFE IDs may call which endpoints), SPIFFE ID matching algorithm, JWT-SVID replay protection, and rate limiting policy are defined in `infrastructure/identity-and-auth-contract.md`. This section describes the mechanism; the contract is the source of truth for policy.

A JWT-SVID is a second authentication layer on top of mTLS -- a request must pass both the mTLS handshake and carry a valid JWT-SVID. This replaces the HMAC bearer secret scheme; no shared secret is stored or distributed.

WOL realm requests a JWT-SVID from its local SPIRE Agent (`WorkloadApiClient.FetchJwtSvidAsync(audience: "spiffe://wol/accounts")`), includes it as `Authorization: Bearer <jwt-svid>` on every request, and the accounts API verifies it against the SPIRE trust bundle fetched from its own local Agent. The JWT is short-lived (5-minute default expiry); the SPIRE SDK caches and renews it transparently. See `spiffe-spire-workload-identity.md` Section 4 for the full JWT-SVID flow and comparison to the old HMAC scheme.

### Mutual TLS on the private link

All communication between WOL and the accounts API uses mutual TLS (mTLS) via SPIRE-issued X.509-SVIDs. Both sides present certificates issued by the SPIRE Server CA:

- **wol-accounts** presents its X.509-SVID (`spiffe://wol/accounts`) -- callers verify it against the SPIRE trust bundle before sending any request.
- **Each caller** (realm, server) presents its own X.509-SVID -- wol-accounts requires and verifies a valid SVID before completing the TLS handshake. A connection from an unknown or unattested workload is rejected before any HTTP traffic is exchanged.

Per-workload SVIDs allow individual callers to be revoked without affecting others. Revocation enforcement per stack is defined in the private-ca proposal (.NET: OCSP fail-closed, PostgreSQL: CRL fail-closed).

**mTLS is the primary authentication mechanism for the private link.** The JWT-SVID bearer (above) is a second, application-layer check on top -- defence in depth, not a fallback.

Both sides present X.509-SVIDs obtained from their local SPIRE Agent via the Workload API. The SPIRE SDK handles cert loading, hot-reload, and trust bundle distribution automatically -- no cert file paths or CA cert files are stored in environment variables. See `spiffe-spire-workload-identity.md` Section 3 for the integration details.

---

## Password Flows

### Register flow

1. WOL collects account name, email, and password from the player (telnet: plaintext lines; WebSocket: JSON fields over WSS)
2. WOL calls `POST /accounts` with `{ name, email, password }` over mTLS
3. Accounts API validates name format and uniqueness, validates email format, hashes password with BCrypt (work factor 12), stores hash; rejects `422` on validation failure
4. If `409 Conflict` (email or name already taken), WOL informs the player and restarts the registration flow

### Authenticate flow

1. WOL receives password (telnet: plaintext line; WebSocket: JSON field over WSS)
2. WOL calls `POST /auth/login` with `{ email, password }` -- single call; the API handles everything
   - API fetches stored hash and lockout state in one DB query
   - If account does not exist: API runs `bcrypt.checkpw(password, DUMMY_HASH)` to consume ~300ms, then returns `401` with a generic message identical to the wrong-password response -- prevents timing-based email enumeration
   - If locked: API returns `423 Locked` with `locked_until`
   - API runs `bcrypt.checkpw(password, stored_hash)` in an executor thread
   - If password wrong: API atomically increments `failed_login_attempts`, locks if threshold reached (purging sessions in the same transaction), returns `401` with generic message
   - If password correct: API resets `failed_login_attempts`, upserts session, returns `201` with token
3. WOL handles the response:
   - `201` → store token on connection, hand off to game session
   - `401` → inform player of invalid credentials (do NOT distinguish account-not-found from wrong-password)
   - `423` → inform player of lockout with time remaining
   - Network/API error → inform player of a server error, close connection

---

## New Repo: `wol-accounts`

Standalone C#/.NET service and independent git repository. Runs on its own machine on the private network.

### Directory layout

```
wol-accounts/
  src/
    Wol.Accounts/
      Program.cs                  # ASP.NET Core minimal API, routes, DI, Kestrel config
      Wol.Accounts.csproj
  migrations/
    001_initial.sql
  tools/
    Wol.Accounts.Migrate/
      Program.cs                  # Migration runner (Npgsql, wol_migrate user, deployment step)
      Wol.Accounts.Migrate.csproj
  tests/
    Wol.Accounts.Tests/
      AccountTests.cs
      SessionTests.cs
      Wol.Accounts.Tests.csproj
  .env.example
  README.md
```

### Database users

Two PostgreSQL users are required:

| User | Permissions | Purpose |
|------|-------------|---------|
| `wol_migrate` | `CREATE TABLE`, `CREATE INDEX`, `GRANT`; ownership of all wol tables; full access to `schema_migrations`; authenticates via client certificate (mTLS) | Runs migrations and issues GRANTs as a deployment step; not used by the running API |
| `wol` | `SELECT/INSERT/UPDATE/DELETE` on `accounts` and `sessions` tables and their sequences; no access to `schema_migrations`; authenticates via client certificate (mTLS) | Used by the running API server; no DDL or migration permissions |

### Schema migration process

Migrations are a **deployment step**, not part of API startup. Before starting the API, the deployment process runs:

```
dotnet run --project tools/Wol.Accounts.Migrate
```

using the `wol_migrate` database credentials. This tool:

1. Creates the `schema_migrations` tracking table if it does not exist.
2. Reads all `.sql` files from `migrations/` in filename order.
3. For each file not already recorded in `schema_migrations`, runs it inside a transaction and records it on success.
4. A failed migration aborts the deployment -- the API is not started.

The running API server uses the `wol` user (no DDL permissions) and does not run migrations itself.

**`wol_migrate` credential handling:** Because `wol_migrate` has DDL and GRANT privileges, its credentials must not be stored persistently on the API server disk. They must be injected at deploy time (e.g., via CI secrets injection or a secrets manager) and discarded after the migration run completes. The API server's process environment must never contain `wol_migrate` credentials. Short-lived, just-in-time credentials (generated per deployment) are the target direction for this user.

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

CREATE TABLE accounts (
    id                     BIGSERIAL    PRIMARY KEY,
    email                  TEXT         NOT NULL UNIQUE,
    name                   TEXT         NOT NULL,            -- display name, original capitalisation
    name_lower             TEXT         NOT NULL UNIQUE,     -- lowercase; enforces global case-insensitive uniqueness
    password_hash          TEXT         NOT NULL,
    failed_login_attempts  INT          NOT NULL DEFAULT 0,
    locked_until           TIMESTAMPTZ,
    created_at             TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- No explicit index on email or name_lower -- the UNIQUE constraints create indexes implicitly

CREATE TABLE sessions (
    id            BIGSERIAL    PRIMARY KEY,
    account_id    BIGINT       NOT NULL UNIQUE REFERENCES accounts(id) ON DELETE CASCADE,  -- UNIQUE enforces one session per account
    token_hash    TEXT         NOT NULL UNIQUE,   -- SHA-256 of the plaintext token
    created_at    TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    expires_at    TIMESTAMPTZ  NOT NULL,
    last_seen_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- No explicit index on token_hash or account_id -- both UNIQUE constraints create indexes implicitly
CREATE INDEX sessions_expires_idx ON sessions (expires_at);

-- Grant app-user permissions (run by wol_migrate after table creation)
GRANT SELECT, INSERT, UPDATE, DELETE ON accounts, sessions TO wol;
GRANT USAGE, SELECT ON SEQUENCE accounts_id_seq, sessions_id_seq TO wol;
```

(No `IF NOT EXISTS` -- migrations run in transactions tracked by `schema_migrations`.)

### Expired session cleanup

A background task runs periodically (configurable interval, default 1 hour) to delete sessions where `expires_at < NOW()`. This prevents unbounded table growth and limits data exposure in a DB compromise.

### API endpoints

All endpoints except `GET /health` require a valid JWT-SVID in the `Authorization: Bearer` header, verified against the SPIRE trust bundle (see "Per-request authorization (JWT-SVID)" above).

CORS is explicitly disabled -- the accounts API is a server-to-server API and must not be callable from browsers.

| Method | Path                    | Description |
|--------|-------------------------|-------------|
| `GET`  | `/health`               | Liveness check -- unauthenticated, by design |
| `POST` | `/accounts`             | Register a new account (API hashes password) |
| `POST` | `/accounts/exists`      | Check if an email is registered |
| `POST` | `/accounts/name-available` | Check if an account name is available |
| `POST` | `/auth/login`           | Authenticate and create session -- single atomic endpoint handling verification, failure counting, lockout, and session creation |
| `POST` | `/sessions/validate`    | Validate a session token (heartbeat + realm login gate) |
| `POST` | `/sessions/revoke`      | Invalidate a session |

**Why POST for all identity-bearing endpoints:** Email addresses are PII and session tokens are credentials. Both are routinely captured in reverse-proxy access logs, API gateway metrics, APM traces, and exception trackers when placed in URL paths. All sensitive values are encoded in POST request bodies. `GET` requests with PII or tokens in the path are prohibited.

**Why `POST /auth/login` does everything:** Splitting verification (`POST /accounts/password-hash`) from failure-reporting (`POST /accounts/login-failed`) and session creation (`POST /sessions`) means correct lockout enforcement depends on every caller faithfully reporting failures. A buggy or compromised realm can simply omit the failure-report call and bypass lockout entirely. A single atomic endpoint removes this trust assumption -- the API controls all security decisions regardless of caller behaviour.

---

#### `GET /health`

Unauthenticated. Intended for internal monitoring tools only. Reveals nothing but service liveness.

Responses:
- `200 OK` `{ "status": "ok" }`
- `503 Service Unavailable` `{ "status": "db_unavailable" }`

---

#### `POST /accounts`

Request:
```json
{ "name": "Alaric", "email": "player@example.com", "password": "plaintext-over-mTLS" }
```

The API normalises `email` to lowercase and `name` to `name.strip()` before validation and storage. `name_lower` is computed as `name.strip().lower()`. The API hashes the password with `BCrypt.Net.BCrypt.EnhancedHashPassword(password, workFactor: 12)` before storing -- the plaintext is never written to disk or logged.

Validation:
- `name`: 3-15 characters, alphabetic only (A-Z, a-z), globally unique (case-insensitive)
- `email`: valid format (contains `@`, non-empty local and domain parts), max 254 characters
- `password`: non-empty, max 72 characters (BCrypt silently truncates at 72 bytes; exceeding this would allow two different plaintexts to produce the same hash)

Responses:
- `201 Created`
- `409 Conflict` -- email or name already registered
- `422 Unprocessable Entity` -- validation failure

---

#### `POST /accounts/exists`

Request:
```json
{ "email": "player@example.com" }
```

**Known risk -- email enumeration:** This endpoint reveals whether an email is registered. This is an accepted trade-off for the current login flow (WOL must know whether to show "register" or "login" prompts). It is tracked as a known risk with the following compensating controls:

- **Rate limit:** 10 req/min per caller SPIFFE ID (see `RATE_LIMIT_EXISTS_PER_CALLER_RPM`). Exceeding this returns `429`.
- **Uniform response time:** The endpoint must take at least ~50ms regardless of whether the account exists (add a `asyncio.sleep` floor if the DB is faster). This prevents timing-distinguishable responses even when rate limiting isn't the concern.
- **Abuse detection:** Alert when more than N distinct email lookups are made per caller SPIFFE ID per minute (configurable; default: alert at 20 unique emails/min). Logged to the security event stream.
- **Caller discipline:** WOL must only call this endpoint at registration time to provide UX feedback -- not as part of every login attempt. Using it to probe whether credentials are valid is a misuse.
- **Future remediation:** Email confirmation (planned) will bind accounts to verified addresses, making enumeration less useful to attackers.

Responses:
- `200 OK` `{ "exists": true | false }`

---

#### `POST /accounts/name-available`

Checks whether an account name is available for registration. Used by WOL to provide player feedback during the registration flow.

Request:
```json
{ "name": "Alaric" }
```

The API normalises the name (strip, lowercase) and checks the `name_lower` column. Same rate limiting as `POST /accounts/exists` (configurable via `RATE_LIMIT_EXISTS_PER_CALLER_RPM`).

Unlike email enumeration, name enumeration is a lower security risk because account names are intended to be publicly visible.

Responses:
- `200 OK` `{ "available": true | false }`
- `422 Unprocessable Entity` -- name fails format validation (non-alphabetic, too short/long)
- `429 Too Many Requests` -- rate limit exceeded

---

#### `POST /auth/login`

The single atomic endpoint for authentication. Replaces the previous three-call sequence (password-hash fetch → local BCrypt verify → login-failed/session create). Failure counting and session creation are server-controlled regardless of caller behaviour.

Request:
```json
{ "email": "player@example.com", "password": "plaintext-over-mTLS" }
```

Server-side sequence:
1. Fetch stored hash, lockout state, and failed attempt count (one DB query). If account does not exist, set `stored_hash = DUMMY_HASH` and mark `not_found = True`.
2. If locked: return `423`
3. `BCrypt.Net.BCrypt.EnhancedVerify(password, stored_hash)` on a background thread via `Task.Run` -- **this runs even when `not_found = True`**, using the pre-configured `DUMMY_HASH` (a pre-computed BCrypt hash stored in configuration at startup). This ensures the response time is always ~300ms regardless of whether the account exists, preventing timing-based email enumeration via the login endpoint.
4. **If `not_found` or password wrong:** `UPDATE accounts SET failed_login_attempts = failed_login_attempts + 1 WHERE email = ...` (skipped if `not_found`); if count reaches threshold, also set `locked_until = NOW() + lockout_duration` and `DELETE FROM sessions WHERE account_id = ...` (same transaction -- purges active sessions on lockout); return `401`
5. **If password correct:** `UPDATE accounts SET failed_login_attempts = 0, locked_until = NULL ...`; upsert session via `INSERT ... ON CONFLICT (account_id) DO UPDATE SET token_hash = ..., expires_at = ..., created_at = NOW(), last_seen_at = NOW()`; return `201`

Token generated via `RandomNumberGenerator.GetBytes(32)` encoded as URL-safe Base64, stored as `SHA256(token)`. The plaintext token is returned once and never stored.

**Uniform error responses:** `401` is returned for both "account not found" and "wrong password." The caller cannot distinguish the two -- this prevents email enumeration through login probing. The dummy-hash path (step 3) also eliminates the timing oracle: an attacker cannot distinguish non-existent accounts from wrong passwords by measuring response latency.

Responses:
- `201 Created` `{ "token": "...", "account_id": 42, "account_name": "Alaric", "expires_at": "2026-03-25T02:00:00Z" }`
- `401 Unauthorized` `{ "error": "invalid_credentials" }` -- account not found OR wrong password (indistinguishable)
- `423 Locked` `{ "locked_until": "2026-03-24T12:15:00Z" }` -- account is locked
- `429 Too Many Requests` -- rate limit exceeded

---

#### `POST /sessions/validate`

Token is passed in the request body -- never in the URL path or query string (tokens in URLs are captured by access logs at every layer).

Request:
```json
{ "token": "urlsafe-base64-token" }
```

Computes `SHA-256(token)` and looks up `token_hash`. Checks `expires_at > NOW()` and `last_seen_at > NOW() - INACTIVITY_TIMEOUT`. Updates `last_seen_at` on success. Returns `404` for expired, timed-out, or non-existent tokens -- no distinction is made between these cases.

**Primary use cases:**
- A WOL realm validates the account session token as the first step of realm login.
- WOL's periodic heartbeat during active gameplay (default: every 5 minutes).
- A WOL realm validates a token presented by a reconnecting WebSocket client.
- A future service (web frontend, character service, etc.) verifies a player's identity.

This is the cross-service authentication primitive for the WOL ecosystem.

Responses:
- `200 OK` `{ "account_id": 42, "account_name": "Alaric", "expires_at": "..." }`
- `404 Not Found` -- invalid, expired, or inactive token

(Email is intentionally omitted from this response. Consumers use `account_id` as the stable identifier and `account_name` as the display name.)

---

#### `POST /sessions/revoke`

Token is passed in the request body.

Request:
```json
{ "token": "urlsafe-base64-token" }
```

WOL calls this on clean connection close, on disconnection detection, and on idle timeout. Failures are logged but do not block the caller -- the session expires naturally at `expires_at`.

Responses:
- `204 No Content`
- `404 Not Found`

---

### Configuration

```
# Database -- app user (mTLS: sslmode=verify-full + step-ca-managed client cert)
DATABASE_URL=postgres://wol@db-host:5432/wol?sslmode=verify-full&sslrootcert=/path/to/ca.crt&sslcert=/path/to/wol-accounts.crt&sslkey=/path/to/wol-accounts.key

# Database -- migration user (same mTLS requirements)
MIGRATE_DATABASE_URL=postgres://wol_migrate@db-host:5432/wol?sslmode=verify-full&sslrootcert=/path/to/ca.crt&sslcert=/path/to/wol-migrate.crt&sslkey=/path/to/wol-migrate.key

# SPIRE -- Workload API socket; provides X.509-SVID (mTLS) and JWT-SVID (bearer) automatically
SPIFFE_ENDPOINT_SOCKET=unix:///var/run/spire/agent.sock

# Session and auth
SESSION_TTL_HOURS=2
SESSION_INACTIVITY_TIMEOUT_MINUTES=30
LOCKOUT_MAX_ATTEMPTS=5
LOCKOUT_DURATION_MINUTES=15
SESSION_CLEANUP_INTERVAL_MINUTES=60
BCRYPT_WORK_FACTOR=12
BCRYPT_MAX_CONCURRENT=8
BCRYPT_DUMMY_HASH=<pre-computed BCrypt hash at configured work factor, generated at first deploy>

# Rate limiting (per caller SPIFFE ID)
RATE_LIMIT_PER_CALLER_RPM=60
RATE_LIMIT_EXISTS_PER_CALLER_RPM=10
RATE_LIMIT_SESSIONS_PER_ACCOUNT_PER_HOUR=10
```

Note: `SSL_CERT`, `SSL_KEY`, and `SSL_CA_CERT` are **not used** -- the accounts API obtains its X.509-SVID and trust bundle from the local SPIRE Agent via `SPIFFE_ENDPOINT_SOCKET`. PostgreSQL client cert paths (in `DATABASE_URL`) are managed by step-ca's renewal daemon, not SPIRE (see `private-ca-and-secret-management.md` Section 5 and `spiffe-spire-workload-identity.md` Section 5).

`sslmode=verify-full` requires PostgreSQL to present a server certificate signed by the CA, and the accounts API presents its own client certificate to PostgreSQL. Both `wol` and `wol_migrate` users have their own client certs. PostgreSQL must be configured with `ssl = on`, `ssl_cert_file`, `ssl_key_file`, and `ssl_ca_file` pointing to the shared CA cert to enable client cert verification (`clientcert=verify-full` in `pg_hba.conf` for the wol database).

**PostgreSQL client cert identity model:** These client certificates are issued by step-ca with `CN=wol` and `CN=wol_migrate` -- plain username strings, not SPIFFE URIs. PostgreSQL's `clientcert=verify-full` matches the certificate CN to the connecting database username; this works correctly because the CN equals the username. SPIFFE X.509-SVIDs (used for service-to-service mTLS) embed the identity in the SAN URI, not the CN, and PostgreSQL cannot use them for `clientcert=verify-full` -- this is the explicit reason step-ca is retained for database certs. See `spiffe-spire-workload-identity.md` Section 5 for the full rationale.

---

## WOL Server Changes (`wol/`)

### Enforce WSS for WebSocket connections

`ConnectionListener` / `ProtocolDetector` must reject plain WebSocket upgrade requests. The server refuses to start without a valid TLS certificate -- there is no fallback to unencrypted WebSocket.

### mTLS configuration for accounts API calls

`HttpClientHandler` is configured with:
- The realm's client certificate and private key (proving WOL's identity to the server)
- The CA cert used to verify the accounts API server certificate

Certificate validation must never be disabled. All certificate paths are read from environment variables.

**Certificate rotation must not require a restart** -- see the TLS certificate rotation section above. WOL implements hot-reload via `FileSystemWatcher` or `IHttpClientFactory` handler rotation.

### HttpClient timeout

WOL's `HttpClient` must be configured with a timeout (5–10 seconds). Without a timeout, a hung accounts API blocks WOL authentication indefinitely. On timeout, `AccountApiClient` throws, and the login flow informs the player of a server error and closes the connection.

### `IGameConnection` -- session token field

`IGameConnection` is extended with a `SessionToken` property:

```csharp
public interface IGameConnection
{
    ConnectionType ConnectionType { get; }
    string? SessionToken { get; set; }   // set after successful login
    Task SendAsync(string text);
    Task CloseAsync();
}
```

### Replace `AccountStore` with `AccountApiClient`

The in-memory `AccountStore` is replaced by `AccountApiClient`. All sensitive values (email, password, session token) are passed in POST request bodies -- never in URL paths.

`LoginAsync` returns a typed `LoginOutcome`:

```csharp
public enum LoginResult { Success, InvalidCredentials, AccountLocked }

public record LoginOutcome(
    LoginResult Result,
    string? Token = null,
    long AccountId = 0,
    string? AccountName = null,
    DateTimeOffset? LockedUntil = null);
```

New file: `wol/Wol.Server/Auth/AccountApiClient.cs`

```csharp
public sealed class AccountApiClient
{
    private readonly HttpClient _http;

    public AccountApiClient(HttpClient http) => _http = http;

    /// <summary>Returns true if an account with this email exists.</summary>
    public Task<bool> ExistsAsync(string email) { ... }

    /// <summary>Returns true if the account name is available.</summary>
    public Task<bool> IsNameAvailableAsync(string name) { ... }

    /// <summary>
    /// Registers a new account. Sends plaintext password to accounts API over mTLS.
    /// The API hashes with BCrypt (work factor 12) server-side.
    /// Returns false on 409 Conflict. Throws on other errors.
    /// </summary>
    public Task<bool> CreateAsync(string name, string email, string password) { ... }

    /// <summary>
    /// Authenticates and creates a session in one call.
    /// Sends plaintext password to accounts API over mTLS.
    /// Returns a typed LoginOutcome -- never throws for 401/423 (only for network/server errors).
    /// </summary>
    public Task<LoginOutcome> LoginAsync(string email, string password) { ... }

    /// <summary>
    /// Validates a session token. Used at realm login and as a heartbeat during gameplay.
    /// Returns null if the token is invalid/expired.
    /// </summary>
    public Task<SessionInfo?> ValidateSessionAsync(string token) { ... }

    /// <summary>
    /// Revokes a session. Called on clean close, disconnection, and idle timeout.
    /// Failures are logged but do not throw -- session expires naturally.
    /// </summary>
    public Task RevokeSessionAsync(string token) { ... }
}
```

`LoginStateMachine` is updated to:
- Take `AccountApiClient` instead of `AccountStore`
- Call `LoginAsync` (single call for authentication; no local BCrypt)
- Switch on `LoginOutcome.Result` to display distinct messages per failure mode
- Handle `false` from `CreateAsync` (registration race condition)
- Handle exceptions from `LoginAsync` (server/network error → inform player, close connection)
- Store the session token on `IGameConnection.SessionToken` after successful login
- Schedule a heartbeat timer (5 minutes) that calls `ValidateSessionAsync`; disconnect player on `null` response

### SPIRE and mTLS configuration

All sensitive config is read from environment variables in `Program.cs`. `appsettings.json` must never contain secrets or certificate paths.

```
WOL_ACCOUNTS_API_URL=https://wol-accounts-host:8443
SPIFFE_ENDPOINT_SOCKET=unix:///var/run/spire/agent.sock   # SPIRE Workload API socket
```

The SPIRE SDK (`Spiffe.WorkloadApi` NuGet package) fetches the realm's X.509-SVID and trust bundle from the local SPIRE Agent automatically. `X509Source` provides hot-reload without restart. No cert file paths, CA cert paths, or shared secrets are stored in environment variables -- the SPIRE Agent manages all of this.

### BCrypt removed from WOL

`BCrypt.Net-Next` is **removed** from `Wol.Server.csproj`. All BCrypt operations now occur inside the accounts API. WOL never hashes, stores, or verifies passwords.

---

## Affected Files / Repos

| Repo | File | Change |
|------|------|--------|
| new `wol-accounts` | `src/Wol.Accounts/Program.cs` | New ASP.NET Core service |
| new `wol-accounts` | `migrations/001_initial.sql` | Schema (accounts + sessions + lockout fields) |
| new `wol-accounts` | `tools/Wol.Accounts.Migrate/Program.cs` | Migration runner (wol_migrate user, deployment step) |
| new `wol-accounts` | `tests/Wol.Accounts.Tests/` | Account and session endpoint integration tests |
| `wol` | `Wol.Server/Network/ConnectionListener.cs` | Reject plain WS; fail startup without TLS cert |
| `wol` | `Wol.Server/Network/IGameConnection.cs` | Add `SessionToken` property |
| `wol` | `Wol.Server/Network/TelnetConnection.cs` | Implement `SessionToken` |
| `wol` | `Wol.Server/Network/WebSocketConnection.cs` | Implement `SessionToken` |
| `wol` | `Wol.Server/Auth/AccountApiClient.cs` | New -- replaces AccountStore |
| `wol` | `Wol.Server/Auth/AccountStore.cs` | Deleted |
| `wol` | `Wol.Server/Auth/LoginStateMachine.cs` | Update constructor; call LoginAsync; switch on LoginOutcome; handle heartbeat timer; store token |
| `wol` | `Wol.Server/Program.cs` | Register HttpClient with mTLS client cert + CA cert from env vars; swap AccountStore for AccountApiClient; remove BCrypt.Net-Next |
| `wol` | `Wol.Server/appsettings.json` | No secrets -- all sensitive config from env vars |
| `aicli` | `CLAUDE.md` | Add `wol-accounts` to sub-projects list |

---

## Trade-offs

**Pro:**
- Accounts and sessions persist across restarts
- DB credentials never in the game server process
- BCrypt entirely server-side -- no realm can exfiltrate stored hashes for offline cracking
- Lockout is server-enforced regardless of caller behaviour -- a buggy/malicious realm cannot bypass it
- Single atomic `/auth/login` endpoint -- no split-brain between verification, failure counting, and session creation
- Session tokens in POST bodies -- never in URL logs at any layer
- Heartbeat revalidation bounds revocation-to-eject window to ≤5 minutes
- WSS guaranteed for WebSocket -- plain connections rejected
- Accounts API is private-network only -- not reachable from the internet
- Session tokens hashed in DB -- DB compromise does not yield usable tokens
- Rate limiting per caller SPIFFE ID limits blast radius of a compromised realm
- Migration tracking via `schema_migrations` -- safe for future ALTER TABLE migrations; wol_migrate user keeps least-privilege separation
- Structured audit logging with log-injection protection
- No secrets in source control
- WOL no longer carries BCrypt dependency or timing attack surface

**Con:**
- WOL has a hard dependency on the accounts API -- downtime affects all realms simultaneously
- Authentication is multiple HTTPS round-trips -- acceptable for a login flow, not a hot path
- Telnet passwords travel in cleartext from client to WOL -- inherent protocol limitation, accepted
- mTLS on all private links requires managing a private CA and cert lifecycle for every service and DB user; this is operationally non-trivial but is the stated architectural standard
- Session token lives in WOL process memory for connection lifetime -- inherent and accepted risk
- Heartbeat revalidation has a ≤5-minute revocation propagation window -- a revoked session can survive in-game until the next heartbeat. Push-based revocation (webhook or pub/sub) would close this window immediately, but introduces a new infrastructure dependency; this is deferred as future work
- Session caching at the WOL realm level (keeping a session valid in local memory if the accounts API is temporarily unreachable) would decouple realm availability from API uptime, but at the cost of a window where revocations cannot propagate during outages. This trade-off is deferred as future work.

---

## Security review response

Responses to findings from `proposals/reviews/infrastructure-proposals-security-review-2026-03-25.md` and `proposals/reviews/infrastructure-proposals-review-followup-2026-03-25.md` that are relevant to this proposal.

| Finding | Status | Resolution |
|---------|--------|------------|
| C3 (inconsistent threat boundary: realm authority) | Acknowledged | A compromised realm can enumerate account existence and perform login spraying within rate limits. Resolution: introduce scoped SPIFFE IDs per realm and per-role (read, write, admin). Enforce endpoint-level authorization matrices tied to SPIFFE IDs. Add signed user-context propagation for user-bound operations. This is a cross-proposal concern requiring the normative "Identity and Auth Contract" document. |
| C4 (telnet plaintext credential acceptance) | Acknowledged | The telnet limitation section already acknowledges this risk. Resolution: set a formal deprecation date for plaintext telnet authentication. Require TLS telnet or WSS for password-bearing flows. If legacy telnet must remain, gate it behind one-time pairing codes or out-of-band auth that never sends the long-term password in cleartext. |
| H1 (OCSP/CRL enforcement) | Resolved | Per-stack revocation behavior defined in private-ca proposal Section 1.7. .NET (wol-accounts): `X509RevocationMode.Online` with fail-closed semantics (OCSP check). Conformance test suite verifies behavior. |
| H8 (JWT-SVID replay for write endpoints) | Resolved | Write endpoints require `jti` claim with TTL-windowed deduplication (5-minute cache). Duplicates rejected with `409 Conflict`. `Authorization` headers never logged. Full spec in `infrastructure/identity-and-auth-contract.md`. |
| M5 (unauthenticated health endpoint) | Acknowledged | `/health` is intentionally unauthenticated for monitoring. Resolution: bind health endpoints to private network ranges only via firewall rules. This is already enforced by the bootstrap scripts (port 8080 allowed from 10.0.0.0/20 only). |
| M7 (logging privacy/retention) | Acknowledged | Email addresses are already sanitized before logging (control characters stripped, truncated). Resolution: define a centralized log retention policy (90 days for security events, per private-ca Section 7.2), access controls on log storage, and a redaction policy for PII in non-security logs. |
| M10 (rate limiting: no global abuse controls) | Acknowledged | Per-realm rate limiting is defined but no global service-level ceilings exist. Resolution: add global service-level ceilings, adaptive throttling, and anomaly detection (cross-realm correlated spikes on `exists`, `auth/login`). Define emergency rate limits toggleable during incidents. |
| Followup #1 (auth protocol contradiction) | Resolved | Stale HMAC bearer language removed from the API endpoints section. The normative auth description now references JWT-SVID verification against the SPIRE trust bundle, consistent with the per-request authorization section. |

Findings addressed in other proposals: C2/M1/M3/M4/M8/M11 (private-ca), C5/H3/H4/H5/H7/H9 (wol-gateway), H2/H6 (spiffe-spire/private-ca), M9 (wol-world), L1-L3 (wol-gateway and cross-cutting).

---

## Out of Scope

- Password change / account deletion (future proposal)
- Password minimum length and complexity requirements (WOL concern -- to be addressed in a WOL proposal)
- Email confirmation (planned -- will address the `/exists` enumeration surface)
- Session refresh / sliding expiry
- Rate limiting by IP
- Account roles or permissions
- Character / player profile management (`char_id` and character data are a separate service)
- **Realm-side session caching** for accounts API outage resilience (future work; see Trade-offs)
- **Push-based session revocation** via webhook or pub/sub to close the heartbeat propagation window (future work; see Trade-offs)
- **Short-lived just-in-time `wol_migrate` credentials** (target direction noted; implementation deferred to a secrets management proposal)
