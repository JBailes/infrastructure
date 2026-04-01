# Infrastructure Proposal Review Follow-up (2026-03-25)

This follow-up captures cross-document correctness and security gaps identified while reviewing:

- `proposals/pending/Infrastructure/private-ca-and-secret-management.md`
- `proposals/pending/Infrastructure/spiffe-spire-workload-identity.md`
- `proposals/pending/Infrastructure/wol-accounts-db-and-api.md`
- `proposals/pending/Infrastructure/wol-players-db-and-api.md`
- `proposals/pending/Infrastructure/wol-world-db-and-api.md`
- `proposals/pending/Infrastructure/wol-gateway.md`

## Blockers

1. **Auth protocol contradiction in accounts API proposal**
   - The document states JWT-SVID replaces legacy HMAC bearer secrets.
   - A later section still specifies `Authorization: Bearer <secret>` validated with `hmac.compare_digest()`.
   - This must be normalized before implementation to avoid incompatible auth middleware.

2. **SPIFFE ID naming and authorization pattern inconsistencies across proposals**
   - IDs are expressed as `spiffe://wol/realm/a`, `spiffe://wol/realm-a`, and `spiffe://wol/server-a` in different docs.
   - Authorization examples mix wildcard/prefix concepts with exact allowlist semantics.
   - Define one canonical ID scheme and one matching policy (prefer exact matching for high-trust paths).

3. **World cross-domain integrity relies entirely on application checks**
   - The world data model deliberately uses cross-domain BIGINT references without foreign keys.
   - That enables future DB splitting, but leaves orphan prevention dependent on API correctness and race-free delete/update workflows.
   - Add transactional write rules + periodic integrity checks as mandatory controls.

## High-priority risks

4. **Gateway single-point dependency for NAT + DNS + NTP**
   - Internal hosts depend on one gateway host for outbound internet, DNS forwarding, and time sync.
   - No explicit HA/failover strategy is included.

5. **Firewall management complexity on dual-homed hosts**
   - The design intentionally mixes raw `iptables` and UFW.
   - This is brittle in practice (ordering/backend drift) and should be standardized to one policy layer.

6. **Privileged LXC for high-value dual-homed hosts**
   - Gateway and WOL hosts are documented as privileged LXCs.
   - This should be explicitly accepted as residual risk or moved to VMs/unprivileged containers.

7. **Bulk world-loading consistency semantics are underspecified**
   - Startup relies on multiple independent `/bulk/*` calls.
   - Without snapshot/version pinning, startup can ingest mixed-era data during concurrent builder writes.

8. **Config allowlists loaded from env vars can drift across instances**
   - Validation behavior may diverge between instances if env values differ.
   - Use a versioned configuration artifact and enforce checksum consistency at startup.

## Recommended follow-up actions

1. Publish a single normative "Identity & Auth Contract" doc with:
   - canonical SPIFFE ID grammar
   - exact audience values by service
   - exact authorization matching rules
   - explicit retirement of HMAC bearer mode

2. Add proposal lint checks in CI:
   - detect deprecated auth language (`hmac.compare_digest`, bearer-secret wording)
   - detect inconsistent SPIFFE ID formats
   - detect unauthenticated endpoint declarations lacking network ACL notes

3. Add mandatory integrity controls to world data proposal:
   - cross-domain referential validation on all writes
   - scheduled orphan scanner and startup gate
   - bulk snapshot token/version to guarantee coherent loads

4. Add gateway resilience plan:
   - active/standby gateway design
   - failover routing procedure
   - DNS/NTP continuity policy and monitoring
