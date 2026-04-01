# Infrastructure Proposals Security/Operations Review (2026-03-25)

Scope reviewed:
- `proposals/pending/Infrastructure/private-ca-and-secret-management.md`
- `proposals/pending/Infrastructure/spiffe-spire-workload-identity.md`
- `proposals/pending/Infrastructure/wol-accounts-db-and-api.md`
- `proposals/pending/Infrastructure/wol-players-db-and-api.md`
- `proposals/pending/Infrastructure/wol-world-db-and-api.md`
- `proposals/pending/Infrastructure/wol-gateway.md`

This review focuses on failure modes, security gaps, contradictory requirements, and operationally risky assumptions.

---

## Executive summary

The proposals are directionally solid (mTLS everywhere, SPIFFE/SPIRE adoption, short-lived certs, least-privilege DB users), but there are several **high-risk design gaps** that can cause outages or materially weaken security in production:

1. **PKI profile errors and policy contradictions** that can produce invalid cert profiles or interoperability failures.
2. **Trust-boundary problems** where compromised internal callers can act outside intended authority (notably `account_id` trust in `wol-players`).
3. **Gateway/network hardening gaps** (IPv6 egress bypass, mixed firewall toolchains, privileged container blast radius).
4. **Availability coupling** where infra components become silent single points of failure with unrealistic RTO assumptions.
5. **Spec drift and internal inconsistencies** across docs that can lead to divergent implementations.

---

## Findings

## Critical

### C1) `wol-players` trusts caller-supplied `account_id` without cryptographic/account ownership proof

**Where:** `wol-players-db-and-api.md` (`account_id` trust model)

**Risk:** If a realm is compromised (or buggy), it can query/create/delete characters for arbitrary accounts by sending forged `account_id` values. mTLS/JWT-SVID here only authenticates the realm workload, not the end-user account identity.

**Impact:** Horizontal privilege abuse across player accounts.

**Why this is critical:** The proposal explicitly states `wol-players` does not independently verify `account_id` and trusts WOL to have done session validation.

**Recommendation:**
- Require a **signed account assertion** from `wol-accounts` (JWT with `account_id`, `session_id`, `exp`, `jti`) and verify in `wol-players`, or
- Have `wol-players` call `wol-accounts` for server-side session validation on sensitive operations, or
- Introduce a token exchange where WOL presents session token and receives a short-lived downstream token scoped to players APIs.

---

### C2) TLS certificate profile includes technically incorrect/unsafe field guidance

**Where:** `private-ca-and-secret-management.md` certificate profile table.

**Problems:**
- ECDSA server certs listed with `keyEncipherment` (not appropriate for ECDSA leaf certs).
- CA usages are described under EKU with `keyCertSign`, `cRLSign` (those are **KeyUsage**, not EKU values).
- `pathLen=0` defined for leaf certs (pathLen is a CA constraint, not meaningful on leafs).

**Risk:** Issuance policy mistakes, validator incompatibility, brittle TLS behavior.

**Recommendation:**
- Split normative profile by cert type with correct RFC 5280 semantics.
- For ECDSA leafs: `digitalSignature` only (and optionally keyAgreement as needed by stack).
- CA certs: `basicConstraints CA:TRUE, pathLen:0` for intermediates; no pathLen for leafs.
- Keep EKU to `serverAuth` / `clientAuth` for leaf certs only.

---

### C3) Inconsistent threat boundary: private network trust + unrestricted realm authority

**Where:** accounts/players/world proposals and gateway proposal.

**Risk:** Internal compromise of one realm host becomes broad lateral authority because APIs largely authorize by “is a realm” instead of “which principal/action on whose resource.”

**Impact:** A compromised realm can:
- enumerate account existence,
- perform login spraying within rate limits,
- operate on character data outside its intended player session scope,
- potentially trigger high-impact write operations in world/players APIs depending on endpoint roles.

**Recommendation:**
- Introduce scoped SPIFFE IDs per realm + per-role (read, write, admin).
- Enforce endpoint-level authorization matrices tied to SPIFFE IDs.
- Add signed user-context propagation for user-bound operations.

---

## High

### H1) OCSP/CRL “must check on every client” requirement is operationally brittle and likely not uniformly enforceable

**Where:** `private-ca-and-secret-management.md` and accounts proposal revocation text.

**Risk:** Many TLS stacks and libraries do not reliably enforce OCSP for private PKI mTLS flows by default; attempting strict behavior can cause false negatives/outages or inconsistent enforcement between services.

**Recommendation:**
- Treat short cert lifetimes as primary revocation control.
- Define **one tested revocation strategy per stack** (Python/.NET/Postgres/Envoy) with conformance tests.
- If OCSP is retained, define fail-open/fail-closed behavior explicitly per link and incident mode.

---

### H2) step-ca and SPIRE availability assumptions are optimistic vs defined RTOs

**Where:** private-ca and SPIRE docs.

**Risk:**
- Step-ca standby promotion depends on mass env var changes (`STEP_CA_URL`) during incident.
- SPIRE server uses manual USB-based LUKS unlock path; full host recovery requires physical operator presence.

**Impact:** Recovery can exceed stated service objectives under realistic outages.

**Recommendation:**
- Automate failover endpoints (VIP/DNS + health-based failover) instead of per-service env edits.
- Either formalize longer SPIRE RTO for catastrophic host loss or implement NBDE/Tang (or HSM-backed unlock flow).

---

### H3) Gateway uses a privileged LXC for a high-value chokepoint

**Where:** `wol-gateway.md` host setup.

**Risk:** A privileged container that also runs NAT + DNS + NTP + API routing is a large blast-radius host. Container escape or misconfig compromises network boundary and control plane traffic.

**Recommendation:**
- Prefer VM instead of privileged LXC for gateway.
- Split roles (at minimum isolate DNS/NTP from reverse proxy/NAT), or harden with strict AppArmor/seccomp/capability drops and immutable config.

---

### H4) IPv6 egress bypass not addressed in firewall/NAT design

**Where:** `wol-gateway.md` firewall examples are IPv4-only.

**Risk:** Hosts with IPv6 connectivity may bypass IPv4 NAT restrictions and egress controls entirely.

**Recommendation:**
- Explicitly disable IPv6 where not used, or define equivalent `ip6tables`/nftables policies and routing constraints.

---

### H5) Mixed firewall stacks (`iptables` + `ufw`) can create non-deterministic rule behavior

**Where:** `wol-gateway.md` uses both direct iptables rules and UFW on same host.

**Risk:** Ordering/chain interaction drift, accidental rule shadowing, incident-time confusion.

**Recommendation:**
- Standardize on one firewall management plane (prefer nftables or UFW with generated policy only).

---

### H6) Join-token transitional flow may leak bootstrap secrets via metadata/logging channels

**Where:** `spiffe-spire-workload-identity.md` transitional join-token path.

**Risk:** Tokens passed via cloud-init/user-data can leak via provisioning logs, metadata APIs, templates, or snapshots.

**Recommendation:**
- Use one-time sealed secret delivery with explicit redaction and log-scrubbing requirements.
- Add mandatory post-boot evidence check that token no longer exists in guest files/cloud-init artifacts.

---

### H7) Gateway identity authorization pattern (`spiffe://wol/realm-*`) is underspecified and potentially over-broad

**Where:** `wol-gateway.md` downstream mTLS identity matching.

**Risk:** Pattern/wildcard matching semantics may accept unintended identities depending on Envoy config exactness.

**Recommendation:**
- Enumerate exact SAN URI match strategy with explicit trust domain and path prefix regex policy.
- Add negative tests for malformed SPIFFE IDs.

---

## Medium

### M1) Doc contradictions around step-ca scope and issued cert types

**Where:** `private-ca-and-secret-management.md` scope says PostgreSQL client certs only; architecture text also mentions PostgreSQL server cert.

**Risk:** Operators may issue/manage extra cert classes unintentionally, drifting ownership boundaries.

**Recommendation:** Clarify whether step-ca owns DB **server** cert issuance or only client certs.

---

### M2) Cross-doc dependency path inconsistency

**Where:** `wol-accounts-db-and-api.md` depends path omits `Infrastructure/` segment.

**Risk:** Broken references degrade maintainability and can cause reviewers to apply wrong source-of-truth.

**Recommendation:** Normalize all dependency links and add link-check CI.

---

### M3) Section numbering drift and stale references indicate spec maintenance risk

**Where:** `private-ca-and-secret-management.md` has Section 2 with subheading 4.1/4.2 style mismatch and references to superseded sections.

**Risk:** Teams implement different versions based on mismatched numbering.

**Recommendation:** Add a doc lint pass (headings, internal references, dependency sync) in CI.

---

### M4) NTP guidance mixes daemon-specific settings and includes weaker auth fallback

**Where:** private-ca clock section references `ntpd`/`chrony` with `makestep` and fallback auth text including MD5.

**Risk:** Inconsistent implementations and weaker-than-intended time trust.

**Recommendation:**
- Standardize on one daemon (chrony).
- Prefer NTS or AES-CMAC authenticated internal source only.
- Remove MD5 references.

---

### M5) Health endpoints are unauthenticated without explicit network scoping controls

**Where:** players/world/accounts proposals mark `/health` unauthenticated.

**Risk:** If network boundaries are misconfigured, this expands service fingerprinting surface.

**Recommendation:** Keep unauthenticated but bind/ACL health endpoints to private ranges or monitoring identities only.

---

### M6) World schema intentionally drops cross-domain FKs; no compensating integrity mechanism is defined

**Where:** `wol-world-db-and-api.md` domain split strategy.

**Risk:** Orphaned references and data integrity drift can cause runtime loader failures or undefined game behavior.

**Recommendation:**
- Define periodic integrity jobs and strict write-time validation for all cross-domain references.
- Block publish/reload on integrity check failures.

---

### M7) Name and metadata logging may still have privacy/abuse implications

**Where:** players/account logging sections.

**Risk:** Character names and identifiers can become sensitive in moderation/legal contexts; retention policy is not specified.

**Recommendation:** Define log retention, access controls, and redaction policy centrally.

---

### M8) Per-service DB cert model can create rollout fragility during username/account changes

**Where:** private-ca DB CN=username model.

**Risk:** Operational churn and migration sequencing errors can break DB access.

**Recommendation:** Prioritize `pg_ident`/SAN mapping feasibility spike and timeline to retire CN=username coupling.

---

## Low / hygiene

### L1) API path consolidation at gateway creates coupling; no versioning boundary called out

**Where:** `wol-gateway.md` path-based routes.

**Recommendation:** Reserve explicit `/api/v1/<service>` prefixes to reduce future collision risk.

---

### L2) Explicit test matrix is not centralized

**Where:** all proposals.

**Recommendation:** Add a single “security conformance checklist” doc for:
- mTLS identity verification tests
- JWT audience/expiry negative tests
- revocation behavior tests
- cert rotation hot-reload tests
- firewall/egress policy tests

---

## Recommended immediate pre-approval gates

1. Fix PKI profile table (C2) and re-review by someone with PKI implementation experience.
2. Redesign `wol-players` account ownership proof (C1) before implementation.
3. Resolve gateway hardening baselines (H3/H4/H5) and document authoritative firewall policy.
4. Define realistic SPIRE/step-ca DR model with tested RTOs (H2).
5. Run doc consistency pass to eliminate dependency/reference drift (M1/M2/M3).

---

## Overall assessment

Current proposal set is a strong foundation but **not implementation-ready** for production as-is. The critical items above should be resolved before marking these proposals “approved” or starting irreversible infrastructure rollout.

## Additional findings (extended review pass)

### C4) Telnet plaintext credential acceptance creates an unavoidable credential-compromise channel

**Where:** `wol-accounts-db-and-api.md` (“Telnet limitation”).

**Risk:** User passwords are transmitted in cleartext between client and WOL over telnet. Any on-path observer (ISP, Wi‑Fi, local network, malware with packet capture) can harvest credentials. This is not merely theoretical; it is a direct confidentiality break.

**Impact:** Account takeover, credential stuffing against other services (password reuse), incident response burden.

**Recommendation:**
- Set a formal deprecation date for plaintext telnet authentication.
- Require TLS telnet / WSS for password-bearing flows.
- If legacy telnet must remain, gate it behind one-time pairing codes or out-of-band auth that never sends the long-term password in cleartext.

### C5) SPIRE workload isolation model depends on one-workload-per-host but gateway/wol deployment model uses privileged multi-role containers

**Where:** `spiffe-spire-workload-identity.md` (`spire` group blast radius) + `wol-gateway.md` host model.

**Risk:** The security model acknowledges that any process with socket access can request local SVIDs and recommends one workload per VM. But deployment choices (privileged LXC, multi-function gateway role, potential co-location pressure) increase the chance of violating this assumption over time.

**Impact:** A single host compromise can collapse intended service identity boundaries.

**Recommendation:**
- Make one-workload-per-host a hard normative requirement in all infra proposals.
- Add conformance checks: fail provisioning if more than one workload registration entry is present per host class (except explicitly approved utility hosts).
- For unavoidable multi-role hosts, isolate with per-workload sockets/namespaces and stricter selector constraints.

### H8) JWT-SVID replay window and binding controls are underspecified for high-value endpoints

**Where:** SPIFFE/JWT sections in accounts/players/world proposals.

**Risk:** Short-lived JWT-SVIDs reduce replay risk but do not eliminate it if captured in memory/logging/proxy layers. The docs do not define mandatory proof-of-possession, nonce binding, or request signing for sensitive writes.

**Recommendation:**
- Define whether JWT-SVID is accepted as pure bearer or sender-constrained token.
- For write endpoints (account creation, session revoke, character delete/progress save), require request replay protections (`jti` cache window, monotonic nonce, or signed canonical request hash).
- Ban Authorization header logging explicitly across all components.

### H9) Public certificate issuance flow for WSS is described but not threat-modeled

**Where:** `wol-gateway.md` certbot DNS-01/HTTP-01 text.

**Risk:** Certificate issuance automation is a high-value control point. The proposal does not define DNS credential storage, least privilege for DNS API tokens, issuance audit trail, or rollback/lockdown during compromise.

**Recommendation:**
- Add an ACME operational profile: token scope, storage location, rotation frequency, audit log requirements, emergency revoke/replace playbook.
- Prefer DNS-01 with narrowly scoped API tokens stored in dedicated secret manager paths.

### M9) API-layer validation for critical enum/text fields without DB constraints raises integrity drift risk

**Where:** `wol-players` and `wol-world` schemas store key domain fields as unconstrained TEXT/JSONB.

**Risk:** Any bug, migration script, or direct SQL write can introduce invalid values that runtime loaders are not prepared to handle.

**Recommendation:**
- Keep flexibility, but add minimal DB safeguards: CHECK constraints for known invariants, versioned JSON schema checks for `values`, and pre-publish validation jobs.
- Require all write paths (including admin/builder tooling) to pass the same validator library.

### M10) Rate-limit strategy is per-realm heavy but lacks coordinated global abuse controls

**Where:** accounts/players/world rate-limit sections.

**Risk:** Distributed abusive traffic from multiple compromised realms can still produce meaningful load or enumeration even if each realm is individually capped.

**Recommendation:**
- Add global service-level ceilings and adaptive throttling.
- Add anomaly detection (cross-realm correlated spikes on `exists`, `name-available`, `auth/login`).
- Define incident-mode emergency limits that can be toggled quickly.

### M11) Disaster recovery objectives are stated, but drill acceptance criteria are not measurable

**Where:** private-ca and SPIRE resiliency sections.

**Risk:** “RTO 2 hours” without explicit drill KPIs often passes documentation review but fails in execution.

**Recommendation:**
- Define DR test criteria: start timestamp, recovery checkpoints, max tolerated data loss (RPO), and explicit pass/fail thresholds.
- Require at least one full tabletop + one live failover rehearsal per quarter.

### L3) Dependency references and supersession semantics are still hard to reason about across six docs

**Where:** all infrastructure proposals.

**Risk:** Teams may implement superseded controls (e.g., bearer-secret vs JWT-SVID) in parallel due to mixed language.

**Recommendation:**
- Add a top-level “effective controls matrix” with columns: control, authoritative doc, superseded-by, implementation status.
- Add CI check that every proposal declares `Supersedes:` and `Superseded-By:` metadata when relevant.

---

## Expanded pre-approval gate checklist

In addition to the earlier gates, require the following before approval:

6. **Transport/auth hardening decision:** decide whether plaintext telnet auth remains allowed; if yes, document compensating controls and sunset timeline.
7. **Token replay posture:** publish a normative JWT-SVID replay/binding standard for write endpoints.
8. **ACME security profile:** define DNS/API token management and incident revoke process for public certs.
9. **Data integrity controls:** add compensating validation/check jobs for cross-domain references and unconstrained schema fields.
10. **DR evidence:** provide a documented and measured failover drill result for step-ca and SPIRE.
