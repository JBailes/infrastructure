# Proposal: Private CA and Automated Secret Management

**Status:** Pending
**Date:** 2026-03-24
**Affects:** All WOL ecosystem services and inter-service links

> **Implementation note:** This proposal originally specified step-ca/step-cli
> as the intermediate CA tooling. The implementation uses **cfssl** and
> **openssl** instead (see PR #120). References to step-ca in this document
> describe the original design intent; the actual scripts use cfssl. The CA
> hostname is `ca` (not `step-ca`), paths use `/etc/ca/` (not `/etc/step-ca/`),
> and cert enrollment is automated via `enroll-host-certs.sh`.

---

## Purpose

This proposal defines the WOL offline root CA and the step-ca instance that issues PostgreSQL client certificates. Certificate profiles, TLS policy, and incident response playbooks for the entire PKI ecosystem are also defined here.

Service-to-service TLS certificates and per-request JWT bearer tokens are issued by SPIFFE/SPIRE -- see `spiffe-spire-workload-identity.md`. The SPIRE intermediate CA chains to the WOL offline root CA defined in this proposal.

---

## Scope

This proposal governs:
- The **WOL offline root CA** and its lifecycle (creation, distribution, rotation, storage)
- **step-ca** for PostgreSQL certificates: client certs (`CN=wol`, `CN=wol_migrate`) and server certs for DB hosts
- **Certificate profiles and TLS policy** (Sections 1.5, 1.6) -- define the standard that all certs in the ecosystem must conform to, including SPIRE SVIDs. SPIRE Server enforces these constraints through its own configuration; step-ca does not issue or govern SPIRE SVIDs
- **Incident response and compromise playbooks** (Section 8)
- **Observability** for step-ca and root CA (Section 7) -- SPIRE-specific monitoring is in `spiffe-spire-workload-identity.md`

This proposal does **not** govern:
- Service-to-service TLS certificates -- issued by SPIRE as X.509-SVIDs
- Per-request bearer tokens -- JWT-SVIDs issued by SPIRE
- Public-facing TLS (e.g. the WOL game server's player-facing certificate) -- managed via Let's Encrypt separately

---

## Architecture Overview

```
        WOL Offline Root CA  [air-gapped, offline]
        ├── step-ca Intermediate CA  [dedicated host]
        │     └── signs PostgreSQL client certs (CN=wol, CN=wol_migrate)
        │         and PostgreSQL server cert
        ├── vTPM Provisioning CA     → DevID certs for Proxmox VM vTPMs
        └── SPIRE Intermediate CA   → X.509-SVIDs + JWT-SVIDs (all services)
             (see spiffe-spire-workload-identity.md)
```

---

## Section 1: Certificate Authority (step-ca)

### 1.1 What it is

[step-ca](https://smallstep.com/docs/step-ca/) is a lightweight, open-source private CA designed for automated certificate management in exactly this kind of internal service mesh. It issues X.509 certificates, enforces short lifetimes, and provides an ACME-compatible API and a renewal daemon that services run alongside themselves.

### 1.2 Deployment

- Runs as a `systemd` service on a dedicated host on the private network
- Uses a two-tier CA: an offline **root CA** (key sealed, never online) and an online **intermediate CA** that signs all issued certificates
- The intermediate CA cert is signed by the root during bootstrap and stored on the step-ca host
- All other services trust the root CA cert (distributed once at bootstrap as a signed inventory artefact -- see Section 7)

### 1.3 Certificate Lifetime and Renewal

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| Certificate lifetime | 24 hours | Short enough that a compromised cert expires quickly without explicit revocation |
| Renewal threshold | 80% of lifetime (~19h) | Renewal daemon triggers before the cert is close to expiry |
| Renewal retry backoff | Exponential, up to 1 hour | Tolerates brief step-ca unavailability |
| Emergency mode lifetime | 1 hour | Used during active incident; see Section 10 |

The `step ca renew --daemon` process runs alongside each service. It watches the cert files on disk and replaces them automatically before expiry.

**Certificate hot-reload behaviour (.NET):** All WOL services are C#/.NET. .NET's `HttpClient` and `SslStream` cache `X509Certificate2` objects in memory. Renewing the file on disk does **not** cause the running process to use the new cert. Services using SPIRE SVIDs get hot-reload natively via the SPIRE SDK's `X509Source`. For step-ca-managed DB certs, services must implement explicit hot-reload (e.g., `FileSystemWatcher` or periodic handler rotation via `IHttpClientFactory`). This is a service implementation requirement, not a step-ca limitation.

**SIGHUP reload failure risk:** The `--exec` flag fires the reload command but does not verify the service actually bound to the new certificate. If the reload fails silently (e.g., temporary resource exhaustion, race with an in-progress request), the service continues with the old cert in memory. When that cert expires, TLS handshakes fail without warning.

**Mitigation: use a "verify-then-reload" wrapper script** as the `--exec` target instead of calling `systemctl reload` directly. The wrapper must:
1. Verify the new cert on disk is valid (`step certificate inspect <cert> --format json` and check `notAfter`)
2. Send `SIGHUP` / `systemctl reload <service>`
3. Wait for the service to confirm it is healthy (`curl -sf http://localhost:<port>/health`)
4. If health check fails within 30 seconds, log an error and raise an alert -- the service is running with a stale cert and requires operator investigation

This is required for all step-ca-managed certs (PostgreSQL client certs).

### 1.4 Bootstrap Provisioner (PostgreSQL Certs Only)

Step-ca issues PostgreSQL client certificates (`CN=wol`, `CN=wol_migrate`) and PostgreSQL server certificates for each DB host. The provisioner for these certs is configured once during bootstrap. After the initial cert is issued, the step-ca renewal daemon uses the cert itself as proof of identity for all subsequent renewals -- no stored provisioner token is needed during normal operation.

The provisioner credential is used only at initial enrollment and must never be stored in plaintext config files. Generate it immediately before enrollment, inject it via an out-of-band channel, and discard it after first use.

Service-to-service certificate provisioning is handled by SPIRE -- no step-ca provisioner configuration is needed for those services.

### 1.5 Certificate Profile Standard

All certificates issued by the WOL private CA MUST conform to the following profile. step-ca policy must enforce these constraints; any certificate that cannot be verified against the profile must be rejected.

#### Leaf certificates (server and client)

| Field | Requirement |
|-------|------------|
| Key type | ECDSA P-256 preferred; RSA-4096 if P-256 unavailable |
| Signature algorithm | ECDSA with SHA-256, or RSA-PSS with SHA-256 |
| Key usage | ECDSA: `digitalSignature` only. RSA server certs: `digitalSignature`, `keyEncipherment`. RSA client certs: `digitalSignature` only. |
| Extended key usage | Server certs: `serverAuth`. Client certs: `clientAuth`. Dual-purpose (SPIRE SVIDs): `serverAuth`, `clientAuth`. |
| basicConstraints | `CA:FALSE` (critical). No `pathLen` (pathLen is only meaningful on CA certs). |
| SAN format | Server certs: DNS names (e.g., `db.wol.local`). Client certs: URI (e.g., `spiffe://wol/realm-a`). |
| Lifetime | 24 hours (step-ca leafs); 1 hour (SPIRE X.509-SVIDs) |

#### CA certificates (root and intermediate)

| Field | Requirement |
|-------|------------|
| Key type | ECDSA P-256 preferred; RSA-4096 if P-256 unavailable |
| Key usage | `keyCertSign`, `cRLSign`, `digitalSignature` (critical) |
| Extended key usage | None (EKU is for leaf certs only; CA certs must not carry EKU) |
| basicConstraints | `CA:TRUE` (critical). Intermediate: `pathLen:0` (can sign leafs but not further intermediates). Root: no pathLen constraint. |
| Lifetime | Root: until manual rotation. Intermediate: per-bootstrap (step-ca), 1 week (SPIRE). |

#### General constraints

| Field | Requirement |
|-------|------------|
| RSA minimum | 4096 bits; prefer ECDSA P-256 |
| Prohibited | `keyEncipherment` on ECDSA certs (not applicable to ECDH key agreement); `keyCertSign` or `cRLSign` on leaf certs; EKU on CA certs; wildcard DNS SANs |

**Hostname verification:** All TLS clients MUST perform full hostname verification against the server certificate's SAN DNS name. `InsecureSkipVerify` is prohibited in all service code.

**DB client cert identity model:** PostgreSQL's `clientcert=verify-full` requires the client certificate CN to exactly match the connecting database username. This is inflexible -- if a DB username changes, the cert CN must change, requiring re-enrollment. To manage this:
- Database usernames are treated as stable identifiers (no renames)
- Service account lifecycle (new service, decommission, rename) triggers a controlled re-enrollment cycle; the old cert is revoked on step-ca and the new cert enrolled before the username is changed in the DB
- **Target future direction: use PostgreSQL's `pg_ident.conf`** to map an incoming certificate's SAN URI (SPIFFE ID) to a database role. This would allow step-ca to be decommissioned entirely -- all certs (including DB client certs) would be SPIFFE SVIDs. This doubles down on a single PKI infrastructure rather than maintaining two. Implementing this eliminates the need for the entire Section 1 (step-ca for DB certs) and should be treated as a priority follow-up proposal once `pg_ident.conf` SAN-based mapping is confirmed to work with the PostgreSQL version in use.

### 1.6 TLS Baseline Policy (Algorithm Agility)

All TLS connections within the WOL private network enforce:

| Parameter | Minimum requirement |
|-----------|-------------------|
| TLS version | TLS 1.3 only for service-to-service; TLS 1.2 permitted only for PostgreSQL clients that lack 1.3 support |
| Cipher suites (TLS 1.3) | `TLS_AES_256_GCM_SHA384`, `TLS_CHACHA20_POLY1305_SHA256` |
| Cipher suites (TLS 1.2) | `ECDHE-ECDSA-AES256-GCM-SHA384`, `ECDHE-RSA-AES256-GCM-SHA384` |
| Certificate key type | ECDSA P-256 preferred |
| Session resumption | Disabled on mTLS connections (prevents session ticket key as second secret) |
| HSTS | N/A (private network only) |

These defaults are set in step-ca's configuration and must be verified by a conformance test (see Section 7).

### 1.7 Revocation

With 24-hour cert lifetimes, revocation is largely moot -- a compromised cert expires within a day. For immediate revocation:
- step-ca supports CRL generation (`step ca revoke`) and its built-in OCSP responder
- **Automated denylisting:** When a compromise is declared, an operator runs `step ca revoke <serial>` and all services are instructed to reload their CRL within 15 minutes (see Section 10)
- **OCSP:** step-ca's built-in OCSP responder is enabled. Revocation checking varies by stack (see per-stack table below): .NET checks OCSP with fail-closed semantics, PostgreSQL checks CRL with fail-closed semantics
- The OCSP response cache TTL is set to 1 hour (a compromise between revocation speed and OCSP responder load; step-ca certs are 24h, SPIRE SVIDs are 1h)

#### Revocation behavior per stack

Each runtime handles OCSP/CRL differently. The following defines the tested revocation strategy and fail behavior per stack:

| Stack | Revocation check | Fail behavior | Configuration |
|-------|-----------------|---------------|---------------|
| **C# / .NET (all WOL services)** | `X509RevocationMode.Online` checks OCSP then CRL. `X509RevocationFlag.ExcludeRoot`. | Fail-closed: if OCSP is unreachable, the connection fails. | Set `X509RevocationMode.Online` on all mTLS connections. Services must handle this gracefully with retry + alerting. |
| **PostgreSQL** | Checks CRL via `ssl_crl_file` or `ssl_crl_dir` in `postgresql.conf`. No OCSP support. | Fail-closed: if `ssl_crl_file` is set and the file is unreadable, PostgreSQL refuses all SSL connections. | Set `ssl_crl_file` pointing to the step-ca CRL. A cron job refreshes the CRL file every 15 minutes via `step ca crl > /path/to/crl.pem`. |

**Summary:** All WOL services (.NET) use OCSP with fail-closed semantics. PostgreSQL uses CRL with fail-closed semantics. Both stacks are verified by the conformance test suite (Section 7.3).

### 1.8 CA Resiliency

> **Note:** Even after SPIFFE/SPIRE is adopted for service-to-service certificates, step-ca remains a critical dependency for **PostgreSQL client certificates** (`CN=wol`, `CN=wol_migrate`). The monitoring and resiliency requirements in this section apply to that continued role. If step-ca is down and a PostgreSQL client cert expires, the accounts API and its migration tooling cannot connect to the database. step-ca monitoring must not be removed or deprioritised after SPIRE adoption.

step-ca is a single point of failure for certificate **renewal**. It is not required for day-to-day service operation -- services use their currently-valid certs regardless of step-ca's state.

**Impact of step-ca downtime:**
- Services continue operating normally using their current certs
- If step-ca is down for longer than the remaining cert validity window (~5h for 24h certs renewed at 80%), the affected service's cert expires and TLS handshakes fail

**Mitigations:**
- Monitor step-ca health; alert if renewal attempts fail (see Section 7)
- step-ca state (including intermediate CA key and cert database) is backed up to encrypted off-host storage (e.g., cloud object storage with server-side encryption) daily and after every cert issuance event that changes durable state
- Backup restoration is tested in a drill environment at least quarterly; the procedure is documented in the incident runbook
- **RTO:** step-ca must be restorable from backup within 2 hours of a host failure. RPO: zero (cert database is replicated to standby in real time)
- **Warm standby with DNS failover:** A second step-ca instance is pre-configured with a replicated copy of the intermediate CA key (encrypted at rest). Both instances share the DNS name `step-ca.wol.local`. The gateway dnsmasq configuration serves the primary instance's IP by default. On primary failure, the operator updates the dnsmasq entry to point to the standby IP and runs `systemctl restart dnsmasq` on both gateways. Services use `STEP_CA_URL=https://step-ca.wol.local:8443` (DNS name, not IP), so no per-service env var changes are needed during failover.
- step-ca downtime does not affect service availability until cert expiry; the 24h window gives a meaningful recovery budget

**DR drill acceptance criteria (M11):** step-ca DR drills must be run at least quarterly (one tabletop, one live rehearsal per quarter). A live drill passes if:
1. Primary step-ca is taken offline (simulated failure)
2. Operator completes DNS failover to standby within 15 minutes
3. A test cert renewal succeeds against the standby within 5 minutes of failover
4. Total time from failure detection to successful renewal < 30 minutes
5. All timestamps and actions are logged for post-drill review

---

## Section 2: Authorization Layer

mTLS client certificate verification establishes *who* the caller is. A separate authorization check enforces *what* each caller is permitted to do.

The normative authorization policy (SPIFFE ID matching algorithm, per-service authorization matrices, and JWT-SVID replay protection) is defined in `infrastructure/identity-and-auth-contract.md`. That document is the single source of truth for authorization rules. Service proposals reference it rather than duplicating matrices.

### 2.1 Enforcement Point

Authorization is enforced as middleware in each API service, before any handler logic executes. The middleware:
1. Verifies the client certificate is present and valid (mTLS is enforced at the TLS layer; this is a belt-and-suspenders check)
2. Extracts the caller's realm identity from the verified client cert SAN
3. Checks the caller identity against the permission table in Section 2.1
4. Verifies the JWT-SVID bearer token (see `spiffe-spire-workload-identity.md` Section 4)
5. Logs the caller identity and endpoint for every request (see Section 7)

---

## Section 3: Clock Security

JWT-SVID expiry timestamps depend on all participants having accurate clocks. Clock drift affects JWT validation (`exp` check) and TLS certificate validity windows. It is a security concern, not just an operational one.

### 3.1 NTP Configuration

All hosts in the WOL private network MUST:
- Use authenticated NTP via **Network Time Security (NTS)** (RFC 8915) for upstream pools on the gateway hosts. Internal hosts receive time from the gateway NTP servers over the isolated private network and do not require NTS
- Synchronise against at least two independent NTP sources
- Disable unauthenticated NTP fallback to public servers (which can be manipulated)
- Configure `ntpd` or `chrony` with `makestep 0.1 3` (allow large adjustments only at startup) to prevent an attacker from slowly slewing the clock

### 3.2 Skew Monitoring

- Each service logs the NTP offset from its monitoring daemon at startup and every 5 minutes
- If NTP offset exceeds **15 seconds**, an alert is raised and logged to the security event stream (see Section 7)
- If NTP offset exceeds **30 seconds**, the service MUST log an error and raise a page-level alert. JWT-SVID validation uses standard `exp`/`nbf` checks; excessive clock skew will cause JWT rejections and mTLS handshake failures as cert validity windows diverge
- Sudden large time jumps (>5 seconds in a single correction) are logged as a security event

**Proxmox virtualisation and clock smear:** In Proxmox VE, VMs are susceptible to clock drift during high CPU steal, live migration, or host suspend/resume events -- the guest clock can fall behind or jump forward by several seconds without NTP having time to correct it. Mitigations:
- Configure the Proxmox VE hosts themselves as the primary NTP stratum for their VMs (use `chrony` or `ntpd` on the hypervisor with upstream NTS sources; VMs sync to the hypervisor's NTP server)
- Enable the `virtio-rtc` (or `kvm-clock`) guest clock device on all WOL VMs in Proxmox so the guest hardware clock is kept in sync with the hypervisor clock at the kernel level, reducing the correction burden on NTP
- After any live migration event, verify the guest clock offset before resuming normal operation

### 3.3 Clock Failure Policy

If a service cannot confirm its clock is synchronised (NTP daemon not running, no reachable NTP source):
- The service logs a warning and continues for up to 30 minutes on local clock
- After 30 minutes without NTP confirmation, the service raises a page-level alert
- A host with a drifted clock will experience JWT and mTLS failures; forcing NTP resolution before this point prevents a hard outage

---

## Section 4: Secret Handling at Runtime

Secrets (session tokens, provisioner tokens, private key material) require careful handling to prevent leakage via OS features or debug interfaces.

### 4.1 Memory Handling

- Private key material is stored in memory regions locked with `mlock()` (Linux) or `VirtualLock()` (Windows) to prevent swapping to disk
- Memory regions are zeroed (`memset` + compiler barrier, or `SecureZeroMemory` on Windows) immediately after use
- The `secrets` module is used for nonce generation

**Managed runtime caveat (.NET):** The .NET garbage collector moves objects in memory freely, so `mlock()` on a C# `string` is not reliably achievable without pinning. For .NET services, prioritise:
- Use `ReadOnlySpan<char>` / `Memory<byte>` for key material where possible; keep secrets in local function scopes so they are eligible for GC immediately after use; avoid boxing or `string` for secrets
- The operative control is **short secret lifetime in scope**, not memory pinning

### 4.2 Core Dumps and Crash Reporting

- All services MUST disable core dumps in production: `ulimit -c 0` in the `systemd` unit file (`LimitCORE=0`)
- If crash reporting is used, it MUST be configured to exclude memory regions containing key material. Sentry, Crashpad, and similar tools must have their native exception handlers disabled or filtered
- The `PR_SET_DUMPABLE` flag is set to `0` on Linux (`prctl(PR_SET_DUMPABLE, 0)`) for all processes handling key material
- `ptrace` is restricted: systemd unit files include `NoNewPrivileges=true` and `RestrictPtrace=true`; seccomp filters block `ptrace` system calls in production

### 4.3 Debug Endpoints

- Debug endpoints (e.g., pprof, `/debug/*`) are NEVER enabled in production
- Health endpoints (`/health`) return only `{"status": "ok"}` and no internal state
- Log levels default to `INFO`; `DEBUG` is disallowed in production (env-var guard at startup)

### 4.4 Environment Variable Handling

- Secrets loaded from environment variables are immediately read into secure memory and the environment variable cleared (where the runtime permits)
- Environment variables are never logged at startup -- a startup log message MUST NOT dump `os.environ`

---

## Section 5: Bootstrap Procedure (One-Time Human Steps)

This is the only point at which a human interacts with this system. After this, everything is automated.

### 5.1 Steps

1. **Initialise step-ca:**
   ```
   step ca init --name="WOL Private CA" --dns="step-ca-host" \
     --address=":8443" --provisioner="wol-provisioner"
   ```
   Save the root CA key **offline** with **redundant backups**. The root CA key is generated on an air-gapped machine, used to sign intermediates, then stored offline. The operator maintains multiple independent backups of the key file (encrypted at rest) in separate locations. The recovery procedure is recorded in `wol-docs/infrastructure/ca-inventory.md`.

   The intermediate CA stays on the step-ca host.

2. **Distribute the root CA cert** to every host. Distribution is performed via a signed inventory file:
   - The root CA cert fingerprint is recorded in a signed, version-controlled inventory file in `wol-docs/infrastructure/ca-inventory.md` (signed by at least one authorised operator using GPG)
   - Each host verifies the fingerprint out-of-band before trusting the cert (the human installer confirms the fingerprint matches the inventory)
   - The signed inventory provides an auditable record of what fingerprint was distributed and when

3. **Configure the step-ca provisioner** for PostgreSQL client certificates. Step-ca uses the offline root to sign its intermediate CA; the renewal daemon then manages DB client cert renewal automatically. No one-time tokens or cloud identity provisioners are needed for service-to-service certs -- those are handled by SPIRE.

4. **Configure PostgreSQL** for mTLS: set `ssl = on`, `ssl_cert_file`, `ssl_key_file`, `ssl_ca_file`, and `pg_hba.conf` entries with `clientcert=verify-full` for the `wol` database.

5. **Verify conformance:** Run the conformance test suite (see Section 7) against the newly bootstrapped infrastructure before declaring the bootstrap complete.

After step 5, all ongoing **step-ca certificate** issuance and renewal is fully automatic. SPIRE bootstrap, workload registration, and service deployment have their own operator checkpoints defined in `spiffe-spire-workload-identity.md` and `proxmox-deployment-automation.md`.

### 5.2 Bootstrap Distribution Risks

The root CA fingerprint and provisioner credentials must reach each host securely. Risks and mitigations:

| Risk | Mitigation |
|------|-----------|
| Fingerprint intercepted in transit | Verify out-of-band against the signed inventory; never trust a fingerprint received over the same channel as the cert |
| Provisioner token intercepted | One-time token with 5-minute TTL; an intercepted token can only be used once and the legitimate service will fail to enroll, triggering an alert |
| Inventory file tampered | Inventory is GPG-signed; signature is verified before distributing to any host |
| Root CA key stolen during bootstrap | Root key is never on a networked host; generated offline; stored in locked physical storage |

---

## Section 6: Per-Service Startup Sequence

This section applies to **PostgreSQL client certificate renewal** (step-ca's only remaining responsibility). Service-to-service cert startup is handled by SPIRE -- see `spiffe-spire-workload-identity.md` Section 6.

On every DB-connected service start (after bootstrap):

1. Service checks if a valid DB client cert already exists on disk with remaining lifetime > 1h
2. If not, the step-ca renewal daemon requests a new cert; step-ca checks the CN against the cert profile policy (Section 1.5) and issues a 24h cert
3. Service starts its renewal daemon: `step ca renew --daemon --exec "systemctl reload <service>"`
4. Service verifies NTP synchronisation is within tolerance (Section 3)
5. Service begins normal operation

No human involvement. No manual cert copying.

---

## Section 7: Observability and Policy Enforcement

### 7.1 Mandatory Security Events

Every service MUST emit structured log events for the following:

| Event | Required fields |
|-------|----------------|
| Certificate enrolled | `service`, `cn`, `san`, `serial`, `expires_at`, `provisioner_type` |
| Certificate renewed | `service`, `cn`, `serial`, `old_expires_at`, `new_expires_at` |
| Certificate renewal failed | `service`, `cn`, `serial`, `error`, `remaining_validity_seconds` |
| Certificate revoked | `serial`, `cn`, `reason`, `revoked_by` |
| OCSP check result | `serial`, `status` (good/revoked/unknown), `response_time_ms` |
| Clock skew exceeded | `offset_ms`, `threshold_ms`, `action_taken` |
| NTP sync lost | `last_sync_age_seconds` |
| Provisioner token used | `provisioner_id`, `cn`, `source_ip` |
| Authorisation denied | `caller_spiffe_id`, `endpoint`, `reason` |

### 7.2 SIEM Integration

Security events are forwarded to a SIEM or log aggregation system (e.g. Loki + Grafana, Elastic, or equivalent). At minimum:

- All events from the table above are tagged `severity=security` and indexed separately from application logs
- Alerts are configured for: cert renewal failure (warn), clock skew exceeded (warn), authorisation denied > 5/min (warn), cert revoked (page)
- Log retention: security events are retained for 90 days minimum

### 7.3 Conformance Tests

A conformance test suite verifies that the infrastructure is correctly configured. Tests are run:
- After bootstrap
- After any infrastructure change
- Quarterly as a routine check

The suite verifies:
- All issued certs conform to the profile in Section 1.5 (correct EKU, KU, pathLen, SAN format, key type)
- TLS connections enforce the cipher suite and version policy in Section 1.6
- Clock skew above threshold triggers the correct service behaviour
- A revoked cert is rejected by all relying services within 15 minutes of revocation

---

## Section 8: Incident Response and Compromise Playbooks

### 8.1 Emergency Short-Certificate Mode

During an active security incident, reduce the cert lifetime to 1 hour on step-ca:
```
step ca provisioner update <provisioner> --x509-min-dur=1h --x509-default-dur=1h
```
Services renewing their certs will pick up the shorter lifetime at the next renewal. Existing 24h certs continue to be valid until they expire -- to force immediate replacement, restart each service after updating the provisioner.

### 8.2 Stolen Service Client Certificate

Scope: an attacker has obtained a copy of a service's private key and client cert.

1. Revoke the cert immediately: `step ca revoke <serial>` -- this publishes the revocation via OCSP
2. All services poll OCSP within 1 hour (TTL); revoke propagation is confirmed by monitoring the OCSP check event stream
3. Notify the affected service's team; the service will automatically re-enroll a new cert at its next renewal cycle (within 5 hours); if immediate replacement is needed, restart the service
4. Review audit logs for all requests made using the stolen cert (identifiable by serial number in mTLS access logs)
5. If the attacker made authenticated requests, assess the scope of data accessed; refer to the account/session compromise playbook in `wol-accounts` as appropriate

### 8.3 Stolen Provisioner Credential

Scope: a JWK provisioner token or provisioner password has been obtained by an attacker.

1. Disable the provisioner on step-ca immediately: `step ca provisioner remove <provisioner-id>`
2. Create a new provisioner with a new credential
3. Identify any certs issued using the stolen credential by querying step-ca's cert log (serial numbers, issued-at times, CNs) -- these certs are potentially attacker-controlled
4. Revoke all certs issued after the credential was known to be at risk
5. Re-enroll all affected services using the new provisioner
6. Investigate how the credential was obtained and fix the root cause before re-bootstrapping

### 8.4 step-ca Host Compromise

Scope: the step-ca host has been compromised; the intermediate CA key may be exposed.

1. **Immediate:** Take the step-ca host offline (firewall or power off)
2. **Revoke the intermediate CA cert** by using the offline root CA to revoke it and publish a new CRL
3. **All existing leaf certs are untrusted** -- every service must re-enroll with a new intermediate CA
4. **Bootstrap a new intermediate CA** from the offline root CA on a new, clean host
5. **Update SPIRE Server simultaneously:** The SPIRE Server also chains its intermediate CA to the WOL offline root via `UpstreamAuthority "disk"`. When the step-ca intermediate is revoked, the SPIRE intermediate is NOT automatically affected -- but both share the same root. A new SPIRE intermediate CA must be signed from the offline root at the same time as the new step-ca intermediate, and the SPIRE Server's `UpstreamAuthority` configuration updated to reference the new intermediate. **Both intermediates must be rotated in the same operation** to prevent a split-brain PKI state where the root has been operationally "refreshed" but SPIRE is still issuing SVIDs under an intermediate that was signed at the same time as the compromised one. Use a single coordinated runbook that updates step-ca and SPIRE Server atomically.
6. **Distribute the new intermediate CA cert** to all services (as the new trust anchor for the intermediate, while the root is unchanged)
7. All services re-enroll (restart triggers re-enrollment via startup sequence)
8. Post-incident: audit what the attacker issued during the compromise window using step-ca's cert log backup

### 8.5 Root CA Key Compromise

Scope: the offline root CA key is believed to be compromised.

This is the worst-case scenario -- every cert in the ecosystem must be considered untrusted.

1. Generate a new root CA and new intermediate CA from scratch
2. Bootstrap the entire PKI (Section 5) from the beginning on all hosts
3. Revoke all services' old certs (they will be replaced during re-bootstrap)
4. Update the signed inventory with the new root CA fingerprint
5. Re-distribute the new root CA cert to all hosts out-of-band
6. Treat all sessions that may have been established during the compromise window as potentially attacker-controlled; invalidate all active sessions in the accounts DB

---

## Section 9: Configuration Reference

Services that connect to PostgreSQL require the following step-ca-related environment variables for DB client certificate renewal:

```
# step-ca -- used by the renewal daemon for PostgreSQL client certs only
STEP_CA_URL=https://step-ca.wol.local:8443
STEP_CA_FINGERPRINT=<root CA cert SHA-256 fingerprint -- from signed inventory>

# PostgreSQL client cert paths (managed by step-ca renewal daemon)
TLS_DB_CERT=/etc/wol/certs/db-client.crt
TLS_DB_KEY=/etc/wol/certs/db-client.key
TLS_DB_CA_CERT=/etc/wol/certs/root_ca.crt
```

Service-to-service TLS certificates and JWT-SVID bearer tokens are provided by SPIRE via `SPIFFE_ENDPOINT_SOCKET` -- see `spiffe-spire-workload-identity.md` Section 7.

---

## Section 10: Affected Repos / Services

| Service | step-ca certs | Notes |
|---------|--------------|-------|
| `wol-accounts` | DB client cert (`CN=wol`) | step-ca renewal daemon manages this |
| `wol-accounts` (migration) | DB client cert (`CN=wol_migrate`) | Used at deploy time only |
| PostgreSQL | Server cert | step-ca issues; `pg_hba.conf` with `clientcert=verify-full` |
| `wol` (each realm) | None via step-ca | Service-to-service certs are X.509-SVIDs from SPIRE |
| `aicli` | `CLAUDE.md` | Add step-ca host to infrastructure list |
| `wol-docs` | `infrastructure/ca-inventory.md` | Signed inventory of root CA fingerprint |

---

## Section 11: Trade-offs

**Pro:**
- Short-lived certs (24h) limit blast radius of a compromised cert without requiring revocation
- Per-service DB user certs allow fine-grained revocation and authorization
- step-ca renewal daemon handles cert rotation automatically -- no human interaction after bootstrap
- Comprehensive playbooks and monitoring reduce mean time to containment
- Single offline root CA for the entire ecosystem -- all certs chain to one root

**Con:**
- step-ca is a dependency for PostgreSQL client cert renewal; if it is down for longer than the cert validity window (~5h), DB connections fail on next renewal
- Bootstrap requires careful one-time setup -- mistakes require manual recovery
- NTS-capable NTP server may require additional infrastructure investment on private networks
- Cert rotation is handled natively by the SPIRE SDK's `X509Source` for services using SVIDs; step-ca DB certs require explicit hot-reload in .NET
- Maintaining step-ca alongside SPIRE doubles the PKI operational surface: two CA infrastructures to monitor, back up, and rotate. The `pg_ident.conf` future path (Section 1.5) eliminates this once implemented.
- A compromised step-ca host requires simultaneous rotation of both the step-ca intermediate and the SPIRE intermediate to prevent split-brain PKI state -- the rotation ceremony must be coordinated across both systems (see Section 8.4)
- `mlock()` and memory zeroing are not reliably achievable in .NET's managed runtime; focus instead on short secret lifetime in scope -- see Section 4.1

---

## Security review response

Responses to findings from `proposals/reviews/infrastructure-proposals-security-review-2026-03-25.md` and `proposals/reviews/infrastructure-proposals-review-followup-2026-03-25.md` that are relevant to this proposal.

| Finding | Status | Resolution |
|---------|--------|------------|
| C2 (cert profile errors) | Resolved | Section 1.5 cert profile rewritten per RFC 5280. Split into leaf and CA tables. ECDSA leafs: `digitalSignature` only (no `keyEncipherment`). CA certs: KU `keyCertSign`, `cRLSign` (no EKU). `pathLen:0` only on intermediate CA (not on leafs). Prohibited list updated. |
| H1 (OCSP/CRL operationally brittle) | Resolved | Per-stack revocation behavior defined in Section 1.7: .NET (OCSP fail-closed), PostgreSQL (CRL fail-closed with 15-minute refresh). Conformance test suite verifies both stacks. |
| H2 (step-ca availability/DR) | Resolved | Section 1.8 updated: DNS-based failover via `step-ca.wol.local` (dnsmasq on gateways). No per-service env var changes needed. RTO < 30 minutes. DR drill acceptance criteria defined with quarterly cadence. |
| M1 (scope contradictions: DB server cert) | Resolved | Scope statement updated to include both DB client and server cert issuance. Section 1.4 updated to match. |
| M3 (section numbering drift) | Resolved | Section 2 sub-headings renumbered from 4.1/4.2 to 2.1/2.2. All section numbers now consistent. |
| M4 (NTP auth: MD5 fallback) | Addressed in gateway | The gateway proposal standardizes on chrony with NTS for upstream connections. MD5 references should be removed from this proposal. Internal hosts use the gateway as their NTP source over the isolated network. |
| M8 (DB cert CN=username fragility) | Acknowledged | CN=username coupling creates operational churn during username changes. The `pg_ident.conf` SAN-based mapping direction is already documented (Section 1.5) as a priority follow-up. |
| M11 (DR drill acceptance criteria) | Resolved | Section 1.8 updated with DR drill acceptance criteria: quarterly cadence (tabletop + live), 15-minute failover target, 30-minute total recovery, pass/fail thresholds, logging requirements. |
| Followup #1 (auth protocol contradiction) | Resolved (cross-proposal) | Section 2 authorization layer now references SPIFFE IDs and JWT-SVID verification. All HMAC bearer secret language removed from this proposal and from the accounts proposal. Canonical auth spec is in `infrastructure/identity-and-auth-contract.md`. |

Findings addressed in other proposals: C3/C4 (wol-accounts), C5/H3/H4/H5/H7/H9 (wol-gateway), H6/H8 (spiffe-spire), M5/M7/M9/M10 (service proposals), L1-L3 (wol-gateway and cross-cutting).

---

## Out of Scope

- Public-facing TLS (Let's Encrypt, managed separately)
- step-ca high availability beyond the warm-standby described in Section 1.8 (single instance acceptable at current scale)
- Certificate transparency logging
- HSM (Hardware Security Module) for offline root CA key storage
- Email alerting implementation details (deferred to ops runbook)
