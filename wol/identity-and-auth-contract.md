# Identity and Auth Contract

Normative reference for SPIFFE identity, JWT-SVID authentication, and authorization across all WOL services.

## SPIFFE ID Convention

All workload identities use hyphenated flat format:

```
spiffe://wol/<service-name>
```

For instance-specific services (horizontally scalable), append the instance suffix with a hyphen:

```
spiffe://wol/<service>-<instance>
```

### Canonical SPIFFE IDs

Shared services have a single SPIFFE ID. Per-environment services include the
environment name in the SPIFFE ID (e.g. `world-prod`, `realm-test`).

| SPIFFE ID | Host | UID | Wrapper Path |
|-----------|------|-----|-------------|
| `spiffe://wol/accounts` | wol-accounts (10.0.0.207) | 1002 | `/usr/lib/wol-accounts/bin/start` |
| `spiffe://wol/world-prod` | wol-world-prod (10.0.0.211) | 1004 | `/usr/lib/wol-world/bin/start` |
| `spiffe://wol/world-test` | wol-world-test (10.0.0.216) | 1004 | `/usr/lib/wol-world/bin/start` |
| `spiffe://wol/ai-prod` | wol-ai-prod (10.0.0.212) | 1005 | `/usr/lib/wol-ai/bin/start` |
| `spiffe://wol/ai-test` | wol-ai-test (10.0.0.217) | 1005 | `/usr/lib/wol-ai/bin/start` |
| `spiffe://wol/realm-prod` | wol-realm-prod (10.0.0.210) | 1001 | `/usr/lib/wol-realm/bin/start` |
| `spiffe://wol/realm-test` | wol-realm-test (10.0.0.215) | 1001 | `/usr/lib/wol-realm/bin/start` |
| `spiffe://wol/server-a` | wol-a (10.0.0.208) | 1006 | `/usr/lib/wol/bin/start` |

### Node SPIFFE IDs

Node IDs follow the pattern `spiffe://wol/node/<hostname>`:

| Node SPIFFE ID | Host |
|----------------|------|
| `spiffe://wol/node/wol-accounts` | wol-accounts |
| `spiffe://wol/node/wol-world-prod` | wol-world-prod |
| `spiffe://wol/node/wol-world-test` | wol-world-test |
| `spiffe://wol/node/wol-ai-prod` | wol-ai-prod |
| `spiffe://wol/node/wol-ai-test` | wol-ai-test |
| `spiffe://wol/node/wol-realm-prod` | wol-realm-prod |
| `spiffe://wol/node/wol-realm-test` | wol-realm-test |
| `spiffe://wol/node/wol-a` | wol-a |
| `spiffe://wol/node/wol-gateway-a` | wol-gateway-a |
| `spiffe://wol/node/wol-gateway-b` | wol-gateway-b |

### Rules

- **No slashes in the service path.** `spiffe://wol/realm-prod`, not `spiffe://wol/realm/prod`.
- **Singleton services omit the instance suffix.** `spiffe://wol/accounts`, not `spiffe://wol/accounts-a`.
- **Per-environment services include the env name.** `spiffe://wol/realm-prod`, `spiffe://wol/world-test`.
- **Wildcard matching uses prefix.** `spiffe://wol/realm-*` matches all realm instances (prod + test).

### Authorization Matcher Algorithm

All services use the same SPIFFE ID matching algorithm for authorization decisions. This is the normative definition; implementations must follow it exactly.

**Input:** caller's SPIFFE ID (extracted from JWT-SVID `sub` claim after signature verification), allowlist of permitted patterns.

**Algorithm:**

1. **Parse** the caller ID as a URI. If parsing fails (malformed URI, missing scheme, empty path), reject with `403 Forbidden`. Do not attempt normalization of malformed IDs.
2. **Validate trust domain.** The URI scheme must be `spiffe`, and the authority (host) must be `wol`. Any other trust domain is rejected with `403 Forbidden`.
3. **Extract path.** The path component (after the leading `/`) is the workload identifier (e.g., `realm-a`, `accounts`). The path must contain exactly one segment (no slashes). Multi-segment paths are rejected with `403 Forbidden`.
4. **Match against allowlist.** For each pattern in the endpoint's allowlist:
   - If the pattern ends with `*`, perform a **string prefix match** on the path: the path must start with the pattern prefix (everything before the `*`). Example: pattern `realm-*` matches path `realm-a`, `realm-b`, but not `realm` (no suffix) or `realms-a` (wrong prefix).
   - If the pattern does not contain `*`, perform an **exact string match** on the path. Example: pattern `accounts` matches only `accounts`.
5. **Decision.** If any pattern matches, allow the request. If no pattern matches, reject with `403 Forbidden`.

**Negative test cases** (must all result in `403`):

| Input | Reason |
|-------|--------|
| `spiffe://evil/realm-a` | Wrong trust domain |
| `spiffe://wol/realm/a` | Multi-segment path (contains slash) |
| `spiffe://wol/` | Empty path |
| `spiffe://wol/realms-a` | Does not match `realm-*` prefix |
| `http://wol/realm-a` | Wrong URI scheme |
| `realm-a` | Not a valid URI |

## JWT-SVID Authentication

All service-to-service requests use mTLS (X.509-SVID) plus a JWT-SVID in the `Authorization: Bearer` header. Both layers must pass.

### JWT-SVID Fields

| Field | Value |
|-------|-------|
| `sub` | Caller's SPIFFE ID (e.g., `spiffe://wol/realm-a`) |
| `aud` | Target service's SPIFFE ID (e.g., `spiffe://wol/accounts`) |
| `iat` | Issued-at timestamp |
| `exp` | Expiry (default 5 minutes) |

### Audience Values

| Target Service | Audience |
|---------------|----------|
| wol-accounts | `spiffe://wol/accounts` |
| wol-world-prod | `spiffe://wol/world-prod` |
| wol-world-test | `spiffe://wol/world-test` |
| wol-ai-prod | `spiffe://wol/ai-prod` |
| wol-ai-test | `spiffe://wol/ai-test` |

### HMAC Bearer Secret (Retired)

The HMAC bearer secret scheme from the private-ca proposal is fully retired. No shared secrets are distributed or stored. All authentication uses SPIRE-issued JWT-SVIDs.

### Non-SPIRE Callers

The `wol-web` host (ackmud.com frontend) serves only static Blazor WASM files and does not call any WOL API services. It does not run a SPIRE Agent and has no workload identity. The `ack-web` host (aha.ackmud.com) is on the ACK network and also does not call WOL API services.

## Authorization Matrix

Each service maintains an allowlist of permitted caller SPIFFE IDs per endpoint.

### wol-accounts

| Caller Pattern | Permitted Endpoints |
|---------------|-------------------|
| `spiffe://wol/realm-*` | `POST /accounts`, `POST /accounts/exists`, `POST /accounts/name-available`, `POST /auth/login`, `POST /sessions/validate`, `POST /sessions/revoke` |
| `spiffe://wol/server-*` | `POST /accounts`, `POST /accounts/exists`, `POST /accounts/name-available`, `POST /auth/login`, `POST /sessions/validate`, `POST /sessions/revoke` |
| Unauthenticated | `GET /health` |


| Caller Pattern | Permitted Endpoints |
|---------------|-------------------|
| `spiffe://wol/realm-*` | All character endpoints |
| `spiffe://wol/server-*` | All character endpoints |
| Unauthenticated | `GET /health` |

### wol-world

| Caller Pattern | Permitted Endpoints |
|---------------|-------------------|
| `spiffe://wol/realm-*` | Read endpoints, bulk load endpoints |
| Unauthenticated | `GET /health` |

### wol-ai

| Caller Pattern | Permitted Endpoints |
|---------------|-------------------|
| `spiffe://wol/realm-*` | `POST /v1/dialogue`, `POST /v1/quest`, `POST /v1/describe` |
| Unauthenticated | `GET /health` |

### Health endpoint network scoping

All services expose `GET /health` without authentication for monitoring. This is safe only because health endpoints are scoped to the private network (10.0.0.0/20) via bootstrap script firewall rules (ufw: allow port 8443 from 10.0.0.0/20 only). Health endpoints must never be exposed to external networks. If a deployment misconfiguration exposes a health endpoint externally, the only information leaked is service liveness and (optionally) a `config_checksum` field, not internal state.

## Write Endpoint Replay Protection

JWT-SVIDs are **pure bearer tokens** (not sender-constrained). To mitigate replay of captured tokens on write endpoints, all services enforce `jti`-based deduplication.

### Mechanism

1. The caller includes a `jti` (JWT ID) claim in every JWT-SVID used for a write request. The SPIRE Agent generates `jti` automatically.
2. The target service maintains an in-memory cache of seen `jti` values, keyed by `jti` with a TTL equal to the JWT lifetime (default 5 minutes).
3. On each write request, the service checks if the `jti` has been seen:
   - **Not seen:** accept the request, cache the `jti`.
   - **Already seen:** reject with `409 Conflict` (replay detected).
4. Cache entries expire automatically after the JWT lifetime window, bounding memory usage.

### Scope

Write endpoints requiring `jti` deduplication:

- wol-accounts: `POST /accounts`, `POST /auth/login`, `POST /sessions/revoke`
- wol-world: All `POST`, `PUT`, `DELETE` endpoints
- wol-ai: All `POST /v1/*` endpoints

Read and health endpoints do not require `jti` deduplication.

### Logging prohibition

`Authorization` headers (containing JWT-SVIDs) must **never** be logged by any component. This applies to application logs, reverse proxy access logs, APM traces, and exception trackers. Log filters must strip or redact the `Authorization` header before writing to any log sink.

## Rate Limiting

Every API service implements two tiers of rate limiting:

### Per-caller limits

Each service enforces per-caller rate limits based on the caller's SPIFFE ID (extracted from the JWT-SVID `sub` claim):

| Service | Default Limit | Notes |
|---------|--------------|-------|
| wol-accounts | 120 req/min per caller | |
| wol-world | 120 req/min per caller | Bulk load endpoints may have higher limits |
| wol-ai | 120 req/min per caller, 10 req/min per player | Per-player limit passed in request body |

### Global service-level ceilings

Each service defines a global request ceiling (across all callers) that acts as a circuit breaker. If total inbound traffic exceeds the ceiling, the service returns `503 Service Unavailable` to all callers. This prevents a compromised or misbehaving realm from exhausting service capacity.

Default global ceilings (configurable per service):
- Normal mode: 600 req/min (all callers combined)
- Emergency mode: 60 req/min (toggled via environment variable or SIGHUP)

### Anomaly detection

Services should log rate-limit events with caller identity and endpoint. Operators should monitor for:
- Correlated spikes across multiple callers (coordinated abuse)
- Unusual write volume on read-heavy services (wol-world)
- Repeated validation failures on sensitive endpoints (account creation, login)
