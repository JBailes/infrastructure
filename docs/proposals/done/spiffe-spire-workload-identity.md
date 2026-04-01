# Proposal: SPIFFE/SPIRE Workload Identity

**Status:** Pending
**Date:** 2026-03-24
**Affects:** All WOL ecosystem services; supersedes bootstrap provisioner and bearer secret sections of `private-ca-and-secret-management.md`; updates `wol-accounts-db-and-api.md`
**Depends on:** `private-ca-and-secret-management.md` (offline root CA and cfssl CA for PostgreSQL client certs)

> **Implementation note:** References to step-ca in this document describe the
> original design. The implementation uses **cfssl** instead. The CA hostname
> is `ca` (not `step-ca`), and cert enrollment is automated via
> `enroll-host-certs.sh`.

---

## Purpose

The private-ca proposal identified that JWK provisioner tokens -- whether one-time or long-lived -- are unsuitable for autoscaling and automated disaster recovery without a machine identity mechanism. SPIFFE/SPIRE resolves this cleanly: every host and workload has a cryptographic identity derived from attestable properties of the machine, not from a pre-shared secret.

This proposal adopts SPIFFE/SPIRE as the workload identity fabric for the WOL private network. Concretely:

1. **SPIRE replaces step-ca leaf certificate issuance.** Services receive X.509 SVIDs from their local SPIRE Agent automatically, with no enrollment credential required.
2. **JWT-SVIDs replace the HMAC-derived bearer secret scheme.** Per-request authorization uses short-lived SPIRE-issued JWTs instead of a window-keyed HMAC. The KMS/TPM master key is no longer needed for bearer tokens.
3. **step-ca is retained only for PostgreSQL client certificates**, where the CN=username constraint makes SVID URIs incompatible without schema changes (see Section 5).

---

## SPIFFE/SPIRE Overview

**SPIFFE** (Secure Production Identity Framework for Everyone) is a set of open standards for workload identity. A SPIFFE ID is a URI of the form `spiffe://<trust-domain>/<path>`, e.g. `spiffe://wol/realm-a`.

**SPIRE** (the SPIFFE Runtime Environment) is the reference implementation. It has two components:

- **SPIRE Server** -- issues SVIDs; manages the trust domain; stores registration entries and node attestation state.
- **SPIRE Agent** -- runs on each host; performs node attestation to the SPIRE Server; exposes the Workload API (a Unix domain socket) to local services.

A service calls the Workload API to receive its current X.509-SVID or JWT-SVID. The Agent handles renewal transparently -- the service always holds a valid credential.

**Trust domain naming:** Production uses `spiffe://wol`; staging uses `spiffe://wol-staging`. Each environment runs a completely independent SPIRE Server with its own trust domain -- SVIDs from one environment are not valid in another. Do **not** use `spiffe://wol-prod` -- the production trust domain is simply `spiffe://wol`. The `SPIFFE_TRUST_DOMAIN` environment variable must be set to the correct value for each deployment (`spiffe://wol` in production, `spiffe://wol-staging` in staging).

---

## Architecture

```
                    ┌──────────────────────┐
                    │     SPIRE Server     │  [private network -- dedicated host]
                    │  (trust domain CA)   │
                    └────────┬─────────────┘
                             │ node attestation + SVID issuance
              ┌──────────────┼──────────────┐
              ▼              ▼              ▼
        WOL Realm host  wol-accounts host  DB host
        ┌────────────┐  ┌────────────┐  ┌────────────┐
        │SPIRE Agent │  │SPIRE Agent │  │SPIRE Agent │
        └────┬───────┘  └────┬───────┘  └────┬───────┘
             │ workload       │ workload       │ workload
             │ API (socket)   │ API (socket)   │ API (socket)
             ▼               ▼               ▼
         WOL service    wol-accounts      (not needed --
                        ASP.NET Core     PostgreSQL uses
                                          step-ca certs)
```

Each service requests its SVID from the local SPIRE Agent socket. The Agent renews the SVID before expiry. No credential is stored in config files or environment variables.

---

## Section 1: SPIRE Server

### 1.1 Deployment

- Runs as a `systemd` service on a **dedicated Proxmox VM** on the private network
- Uses the trust domain `spiffe://wol` (production) or `spiffe://wol-staging` (staging) -- set via `SPIFFE_TRUST_DOMAIN` per deployment
- **SPIRE chains to the WOL offline root CA** via `UpstreamAuthority "disk"`. The SPIRE intermediate CA cert is signed by the WOL offline root during bootstrap and stored on the SPIRE Server host. All SVIDs (X.509 and JWT) chain to the same offline root as step-ca DB certs and vTPM DevID certs -- the entire WOL ecosystem shares a single PKI root.

  Unified PKI hierarchy:
  ```
  WOL Offline Root CA
  ├── step-ca Intermediate CA  → PostgreSQL client certs (CN=wol, CN=wol_migrate)
  ├── vTPM Provisioning CA     → DevID certs for Proxmox VM vTPMs
  └── SPIRE Intermediate CA   → X.509-SVIDs + JWT-SVIDs (all service-to-service)
  ```

- The SPIRE Server's CA key manager:
  - **Cloud:** `KeyManager "aws_kms"` with the KMS key ARN
  - **Proxmox VM (this deployment):** `KeyManager "disk"` with the key file on a LUKS-encrypted virtual disk. The LUKS volume is unlocked automatically at boot via **NBDE (Network Bound Disk Encryption)** using Clevis/Tang. The Tang server runs on the `spire-db` host (10.0.0.202:7500). When the SPIRE Server VM boots, Clevis contacts the Tang server over the private network to obtain the LUKS decryption key. No operator intervention or physical access is required.

  **Automated recovery:** After a power loss or reboot, the full infrastructure recovers automatically: Proxmox restarts all VMs/containers, the SPIRE Server VM's LUKS volume is unlocked by Clevis/Tang as soon as the `spire-db` host (Tang server) is reachable, SPIRE Server starts and begins issuing SVIDs, and all services re-attest and resume. The `spire-db` host must be configured to start before the SPIRE Server VM in the Proxmox boot order so that Tang is available when Clevis needs it.

  **Tang server availability:** If the Tang server is unreachable at boot (e.g., the `spire-db` host has not started yet), Clevis retries with exponential backoff. The SPIRE Server VM will wait at the initramfs stage until Tang responds. This is acceptable because all services depend on SPIRE anyway, so nothing can start until SPIRE is up. A second Tang server on a different host (future) would eliminate this single dependency.

  The SPIRE Server VM must not share a Proxmox host with any service it issues SVIDs to, separating the CA key from the workloads it certifies.
- CA certificate lifetime: 1 week (intermediate); root valid until manual rotation
- SVID lifetime: **1 hour** (service SVIDs); **24 hours** (agent SVIDs). Agent SVIDs are longer-lived so that a SPIRE Agent that cannot reach the SPIRE Server (e.g., during a reboot or server maintenance window) continues to authenticate to workloads for the duration. Service SVIDs renew at 50% of lifetime (~30 minutes); agent SVIDs renew at 50% as well (~12 hours).

### 1.2 Trust Bundle Distribution

The SPIRE Server's trust bundle (root CA cert) is automatically distributed to all SPIRE Agents in the trust domain via the server's bundle endpoint. Services fetch the trust bundle from their local Agent's Workload API -- no manual cert distribution is required.

This is the key advantage over step-ca: a new host joining the private network receives the trust bundle automatically after node attestation, without any human distributing a root CA cert file.

### 1.3 Registration Entries

Registration entries map a set of attestable selectors to a SPIFFE ID. Example entries:

| SPIFFE ID | Selectors |
|-----------|-----------|
| `spiffe://wol/realm-a` | `unix:uid:1001` (UID of the wol-realm-a service user) AND `unix:path:/usr/lib/wol-realm/bin/start` |
| `spiffe://wol/accounts` | `unix:uid:1002` AND `unix:path:/usr/lib/wol-accounts/bin/start` (wrapper script -- not the interpreter) |
| `spiffe://wol/db/wol` | Future: if DB-side SPIRE integration is added |

Registration entries are created by an administrator during initial deployment and updated when services are added or removed. This is a human step, but it is idempotent and auditable -- the entries are version-controlled in a SPIRE registration manifest.

### 1.4 HA and Resiliency

A single SPIRE Server is the starting point. If the SPIRE Server is unavailable:
- Services continue operating using their currently cached SVIDs until expiry (service SVIDs: 1-hour window; agent SVIDs: 24-hour window)
- **Warm standby:** A second SPIRE Server host is pre-configured and can be promoted without agent restarts

**Datastore strategy for warm standby:** SPIRE Server's default SQLite datastore cannot be shared between two nodes. For warm standby promotion to work without data loss, the primary SPIRE Server uses a **PostgreSQL datastore** (`Datastore "sql"` with `database_type = "postgres"`). The standby SPIRE Server is pointed at the same PostgreSQL instance (read replica during normal operation; promoted on failover). This ensures registration entries and node attestation state are current on the standby at all times -- there is no backup restore step during a failover.

The shared PostgreSQL instance for SPIRE state is a separate DB from the wol-accounts PostgreSQL. It may run on the same DB host.

**Bootstrap circular dependency:** SPIRE Server's connection to its own PostgreSQL datastore must NOT use SPIRE-issued certificates. If the database requires a SPIRE SVID to accept connections, SPIRE cannot start -- it needs the database to obtain credentials, but it cannot issue credentials without the database. Resolution: SPIRE Server connects to its PostgreSQL datastore using a **static client certificate** issued by the WOL offline root CA directly (not via step-ca, not via SPIRE), or a strong static password. This certificate is provisioned once during bootstrap and renewed manually or via a separate out-of-band process. The wol-accounts PostgreSQL database is unaffected -- it uses step-ca-issued certs, which are not SPIRE-dependent.

SPIRE Server's datastore is backed up daily to encrypted off-host storage as an additional safety net. Recovery SLO: 2 hours.

---

## Section 2: SPIRE Agent

### 2.1 Deployment

One SPIRE Agent per host. Runs as a `systemd` service. Exposes the Workload API at `/var/run/spire/agent.sock`.

**Socket and directory permissions:**

| Path | Owner | Mode | Purpose |
|------|-------|------|---------|
| `/var/run/spire/agent.sock` | `spire:spire` | `0660` | Workload API socket; readable only by the `spire` group |
| `/var/lib/spire/agent/` | `spire:spire` | `0700` | Agent data directory (cached SVIDs, node attestation state); readable only by the `spire` user |

Service users that need to call the Workload API (e.g., `wol-realm` UID 1001, `wol-accounts` UID 1002) must be members of the `spire` group. No other user should be in the `spire` group. This ensures only explicitly permitted service processes can obtain SVIDs from the local Agent -- an attacker with a shell on the host but running under an unpermitted UID cannot impersonate a registered workload.

**spire group blast radius:** Any process in the `spire` group can reach the Workload API socket and request SVIDs for any workload registered on that host. If a service running as `wol-accounts` (UID 1002) is compromised, the attacker can request any SVID the Agent is authorised to issue on that host -- not only the `spiffe://wol/accounts` SVID. **Mitigation: each Proxmox VM should run exactly one functional workload service.** A one-workload-per-VM boundary limits the blast radius: compromising `wol-accounts` yields only the SVIDs registered to the accounts host. Running multiple workloads on the same VM (e.g., both realm and accounts) negates the SPIFFE identity boundary between them.

### 2.2 Node Attestation (Host Identity)

Node attestation proves that a SPIRE Agent is running on a trusted host. The WOL deployment runs on **Proxmox VE virtual machines** -- physical TPM hardware attestation and cloud IMDS are both unavailable. Two options are supported:

#### Option A: vTPM with Local Provisioning CA (Recommended)

Proxmox VE supports vTPM 2.0 devices backed by `swtpm`. Each VM is created with a vTPM device. At VM provisioning time, an automated script:

1. Generates an Endorsement Key (EK) and Device Identity (DevID) key pair inside the VM's vTPM
2. Submits a certificate signing request to a local **vTPM Provisioning CA** (a purpose-specific intermediate CA signed by the WOL offline root)
3. Stores the signed DevID cert in the VM's vTPM

The SPIRE Server's `tpm_devid` attestor is configured to trust the vTPM Provisioning CA. A SPIRE Agent on any VM holding a valid DevID cert attests automatically -- no join token needed for scale-out.

After first attestation, the SPIRE Agent stores its SVID and re-attests on subsequent reboots using the vTPM DevID, with no human involvement.

**Security characteristics of vTPM:** The vTPM's state is managed by the Proxmox host via `swtpm`. Unlike a physical TPM, the vTPM state file can be copied alongside the VM's disk image. Consequences:
- A compromised Proxmox host could clone a VM's vTPM state and impersonate it -- including cloning the accounts-host VM and impersonating it to the SPIRE Server
- VM cloning (creating a new VM from a snapshot) replicates the vTPM state -- the provisioning script must generate a fresh DevID cert for each new VM, not copy it
- Mitigation: the provisioning script is the gating step; cloned VMs without a freshly issued DevID cert cannot attest

**Proxmox host-level logging:** Because a Proxmox root compromise would allow vTPM state theft, Proxmox hypervisor audit logging must be aggressive: all `qm`, `pvesh`, and SSH root access events must be forwarded to the SIEM (see Section 10.4). Unauthorized VM export or snapshot creation events are a priority alert.

**SPIRE Server hardware TPM:** The SPIRE Server VM is the highest-value target -- it issues all SVIDs. If the physical Proxmox host has a hardware TPM chip, it should be passed through to the SPIRE Server VM (`hostpci` passthrough in Proxmox configuration). This ensures the root of trust for SPIRE's own CA key is not entirely virtual. If hardware TPM passthrough is unavailable on the Proxmox hardware, the `KeyManager "disk"` + LUKS approach remains the fallback (see Section 1.1).

This is weaker than hardware TPM attestation but substantially stronger than static pre-shared secrets. For an internal private-network deployment, this is an acceptable tradeoff.

**Proxmox VM creation checklist:**
- Add a vTPM 2.0 device to the VM
- Run provisioning script post-creation (can be automated via Proxmox hooks or Ansible)
- Script must NOT be run against cloned VMs without also generating a new DevID cert

#### Transitional: Automated Join Token via Cloud-Init

During the period before the vTPM Provisioning CA is fully operational (e.g., while the provisioning hook is being developed), automated join tokens are used:

1. The operator runs `spire-server token generate -spiffeID spiffe://wol/node/<vm-name> -ttl 300` (5-minute TTL) on the SPIRE Server
2. The token is written to a temporary file on the Proxmox host, injected into the VM via `pct push` (mode 0600), and the Proxmox-side copy is deleted immediately
3. The SPIRE Agent reads the token from the file on first start; the file is deleted by the agent after consumption
4. On subsequent reboots, the agent re-attests from cached state, no new token needed

**Join token leakage mitigations (H6):**
- Tokens are **never** passed as command-line arguments or environment variables (visible in `/proc`)
- Tokens are **never** placed in cloud-init user data (persists in guest filesystem at `/var/lib/cloud/instance/user-data.txt` and Proxmox snapshots)
- The token file on the target VM is mode 0600, owned by root, and deleted immediately after SPIRE Agent consumes it
- A post-boot verification script (`/usr/lib/spire/verify-no-token.sh`) runs 60 seconds after agent start and confirms: (a) no token file exists at the expected path, (b) no token appears in `/var/log/`, (c) no token appears in cloud-init artifacts under `/var/lib/cloud/`. If any check fails, the script logs a security alert and exits non-zero
- The post-boot verification script is called from the SPIRE Agent systemd unit as `ExecStartPost`

This is a temporary measure during rollout. Once the vTPM path is operational, new VMs use it exclusively. Existing VMs attested via join token continue operating normally (the agent's cached state is independent of the original attestation method).

**Chosen approach:** vTPM + local Provisioning CA (Option A). Join tokens are a transitional fallback only, not a permanent alternative.

### 2.3 Workload Attestation (Process Identity)

Once a SPIRE Agent is attested, it uses the **Unix workload attestor** to match calling processes to registration entries. The attestor inspects:
- The calling process's Unix UID and GID
- The calling process's executable path
- Optionally: the calling process's parent PID (to verify it was spawned by systemd)

Services run under dedicated Unix users (e.g., `wol-realm` with UID 1001, `wol-accounts` with UID 1002). **Every registration entry MUST include both `unix:uid` AND `unix:path` selectors.** UID alone is insufficient -- any process running under that UID (including a shell spawned by the service user for debugging) could obtain the SVID. The `unix:path` selector resolves the calling process's executable via `/proc/<pid>/exe` and must match the installed binary path. Together, the two selectors ensure only the exact expected binary running under the expected UID can obtain its SVID.

---

## Section 3: X.509-SVIDs for mTLS

X.509-SVIDs replace step-ca leaf certificates for all service-to-service mTLS links. An X.509-SVID is a standard X.509 certificate with:
- **Subject:** service identifier (implementation-defined; often just `CN=SPIFFE`)
- **SAN URI:** the SPIFFE ID (e.g., `URI:spiffe://wol/realm-a`)
- **Lifetime:** 1 hour (configurable in SPIRE Server)
- **Key type:** ECDSA P-256
- **EKU:** both `clientAuth` and `serverAuth` (SPIFFE X.509-SVIDs are dual-purpose)

Services receive their X.509-SVID from the local SPIRE Agent via the Workload API. The Agent updates the cert on disk (or provides it via the Workload API stream) before expiry. Services watch the Workload API stream and reload their TLS context when a new SVID is pushed -- no polling, no `FileSystemWatcher`, no restart required.

### 3.1 .NET Integration (all WOL services)

All WOL services (wol, wol-realm, wol-accounts, wol-world, wol-ai) are C#/.NET and use the same SPIRE integration pattern.

The SPIRE Workload API uses gRPC. The C# SPIFFE SDK (`Spiffe.WorkloadApi` NuGet package) provides:
- `WorkloadApiClient.CreateX509Source()` -- returns an `X509Source` that automatically tracks the current X.509-SVID and trust bundle
- The `X509Source` integrates with `SslClientAuthenticationOptions` and `SslServerAuthenticationOptions` via a certificate selection callback
- New TLS connections automatically use the current cert; existing connections continue until closed

This resolves the hot-reload problem identified in the private-ca proposal without any `FileSystemWatcher` or `IHttpClientFactory` rotation logic -- the SPIRE SDK handles it natively. A single SDK (`Spiffe.WorkloadApi` NuGet) is shared across all services, eliminating the need for separate per-language SPIFFE integrations.

### 3.2 Trust Validation

Both sides of an mTLS connection verify the peer's SVID against the SPIRE trust bundle. The trust bundle is fetched from the local Agent's Workload API and updated automatically when it rotates. No root CA cert file distribution is required.

An additional **authorization check** is still required after mTLS: verifying that the peer's SPIFFE ID is permitted to call the requested endpoint. For example, the accounts API checks that the caller's SPIFFE ID matches `spiffe://wol/realm-*` before accepting a request. This is the authorization layer defined in Section 4 of the private-ca proposal, now using SPIFFE IDs instead of client cert CNs.

---

## Section 4: JWT-SVIDs as Bearer Token Replacement

JWT-SVIDs replace the HMAC-derived bearer secret scheme entirely. The KMS/TPM master key and window-based derivation are no longer needed.

### 4.1 How It Works

1. WOL realm requests a JWT-SVID from its local SPIRE Agent: `WorkloadApiClient.FetchJwtSvidAsync(audience: "spiffe://wol/accounts")`
2. SPIRE Agent returns a signed JWT containing:
   - `sub`: `spiffe://wol/realm-a` (the caller's identity)
   - `aud`: `spiffe://wol/accounts` (the intended recipient)
   - `iat`: issued-at timestamp
   - `exp`: expiry (configurable; default 5 minutes)
3. WOL includes the JWT in the request: `Authorization: Bearer <jwt-svid>`
4. The accounts API fetches the SPIFFE trust bundle from its local Agent and verifies the JWT signature, `aud`, and `exp`
5. The accounts API extracts `sub` and applies the authorization rules (same permission table as before)

### 4.2 Advantages Over HMAC Bearer Secret

| Property | HMAC bearer (old) | JWT-SVID (new) |
|----------|------------------|----------------|
| Shared secret required | Yes (master key in KMS/TPM) | No |
| Clock skew handling | Manual (window±1) | Standard JWT `exp` + `nbf` |
| Replay protection | Manual replay cache (jti) | SPIRE JTI + short exp |
| Key rotation | Manual (new KMS key) | Automatic (SPIRE rotates CA) |
| Revocation | Implicit (window changes) | SVID expiry (5-min window) |
| Caller identity | iss field (honour-system) | Cryptographically proven SPIFFE ID |
| WOL implementation | Custom HMAC + token format | SPIFFE SDK call |

### 4.3 JWT-SVID Caching

The SPIRE Agent caches JWT-SVIDs and renews them proactively before expiry. WOL does not need to request a new JWT-SVID on every API call -- it can reuse the cached one until it expires. The SDK handles this transparently via `JwtSource`.

### 4.4 JWT-SVID Replay Protection

JWT-SVIDs are pure bearer tokens (not sender-constrained). To prevent replay attacks, all service **write endpoints** MUST verify the `jti` (JWT ID) claim. Each service maintains a TTL-based in-memory cache (e.g., .NET `MemoryCache` with sliding expiry) of recently seen `jti` values. The cache window equals the JWT lifetime (default 5 minutes). Duplicate `jti` values are rejected with `409 Conflict`. Read and health endpoints do not require `jti` verification (they are idempotent). `Authorization` headers must never be logged by any component.

### 4.5 Removal of Master Key and KMS/TPM for Bearer Secrets

With JWT-SVIDs, the following are no longer required:
- `SECRET_BACKEND`, `KMS_KEY_ID` environment variables (for bearer secrets)
- Master key provisioning steps in the bootstrap procedure
- `BEARER_WINDOW_SECONDS`, `MAX_NTP_SKEW_SECONDS` configuration
- Clock skew section in the private-ca proposal (JWT standard handles this within `exp`)

Note: `KeyManager "tpm"` (physical TPM) is only applicable to physical bare-metal hosts; it is **not** used in this Proxmox VM deployment. The vTPM (swtpm) is used exclusively for *node attestation* (Section 2.2), not as a SPIRE key manager. This is SPIRE's internal concern -- application code is not affected.

---

## Section 5: PostgreSQL Client Certificates (Hybrid Approach)

PostgreSQL's `clientcert=verify-full` matches the client certificate CN to the database username. SPIFFE X.509-SVIDs embed the SPIFFE ID in the SAN URI, not the CN -- PostgreSQL cannot use them for `clientcert=verify-full` without custom configuration.

**Resolution:** step-ca is retained for PostgreSQL client certificates only. This is a narrow exception:
- `wol` DB user: step-ca issues a cert with `CN=wol`
- `wol_migrate` DB user: step-ca issues a cert with `CN=wol_migrate`
- step-ca renewal daemon manages these certs; SPIRE is not involved

All other service-to-service links (WOL ↔ accounts API) use SPIRE SVIDs exclusively.

**Future path:** PostgreSQL's `pg_ident.conf` can map an incoming cert's CN to a different database role, which could allow a SPIFFE URI SAN to map to a DB username if PostgreSQL adds SAN-based matching. This would allow step-ca to be removed entirely. Out of scope for this proposal.

---

## Section 6: Bootstrap Procedure

### 6.1 SPIRE Server Bootstrap

1. Generate SPIRE Server configuration with trust domain `spiffe://wol` (or `spiffe://wol-staging` for staging)
2. Configure the key manager for this deployment:
   - **Proxmox VM (this deployment):** `KeyManager "disk"` with the key file on a LUKS-encrypted virtual disk (unlocked at boot via Clevis/Tang NBDE, see Section 1.1). `KeyManager "tpm"` is **not** applicable here -- it requires a physical TPM chip, which Proxmox VMs do not have (vTPM via `swtpm` is used only for node attestation, not as a SPIRE key manager).
   - Cloud: `KeyManager "aws_kms"` with the KMS key ARN
   - Physical bare-metal only: `KeyManager "tpm"` using the host's hardware TPM
3. Start SPIRE Server; it generates its intermediate CA cert using the UpstreamAuthority (WOL offline root)
4. Record the trust bundle fingerprint in `wol-docs/infrastructure/ca-inventory.md` (GPG-signed, per private-ca bootstrap procedure)

### 6.2 SPIRE Agent Bootstrap (per VM)

**Option A path (vTPM + Provisioning CA -- recommended):**

1. Create a vTPM Provisioning CA: a dedicated intermediate CA signed by the WOL offline root, used only to sign vTPM DevID certs
   ```
   step certificate create "WOL vTPM Provisioning CA" vtpm-ca.crt vtpm-ca.key \
     --profile intermediate-ca --ca root_ca.crt --ca-key root_ca.key
   ```
2. Configure SPIRE Server's `tpm_devid` attestor to trust the Provisioning CA cert
3. For each new VM: run the provisioning script (via Proxmox hook or Ansible) after VM creation:
   - Script generates a DevID key pair inside the VM's vTPM and submits a CSR to the Provisioning CA
   - Signed DevID cert is loaded into the vTPM
4. Start SPIRE Agent; it attests automatically using the vTPM DevID -- no token, no human step
5. Agent caches its SVID; subsequent reboots re-attest from the vTPM without any external call

**Transitional path (join token -- until vTPM Provisioning CA is operational):**

1. Operator runs `spire-server token generate -spiffeID spiffe://wol/node/<vm-name> -ttl 300` on the SPIRE Server (5-minute TTL)
2. Token is written to a temporary file on the Proxmox host, pushed into the VM via `pct push` (mode 0600), and the Proxmox-side copy is deleted immediately. **Tokens must never be injected via cloud-init user data** (persists in guest filesystem and Proxmox snapshots; see Section 2.2 for full leakage mitigations).
3. VM boots; SPIRE Agent reads the token from the file, attests to SPIRE Server, and the file is deleted after consumption. Post-boot verification (Section 2.2) confirms no token artifacts remain.
4. Agent caches its SVID; subsequent reboots re-attest from cached state without a new token

### 6.3 Registration Entries

Register workload entries for each service:

```bash
spire-server entry create \
  -spiffeID spiffe://wol/realm-a \
  -parentID spiffe://wol/node/wol-realm-a \
  -selector unix:uid:1001 \
  -selector unix:path:/usr/lib/wol-realm/bin/start

spire-server entry create \
  -spiffeID spiffe://wol/accounts \
  -parentID spiffe://wol/node/wol-accounts \
  -selector unix:uid:1002 \
  -selector unix:path:/usr/lib/wol-accounts/bin/start
```

**All WOL services are compiled .NET binaries**, so the `unix:path` selector points directly to the published executable (e.g., `/usr/lib/wol-accounts/bin/Wol.Accounts`). Unlike interpreted languages where the interpreter path is shared across all services, .NET publishes a self-contained or framework-dependent executable per service, giving each a unique binary path. No wrapper script is needed.

The binary is owned by root, not writable by the service user, and is specific to this service.

**`unix:sha256` selector:** SPIRE also supports a `unix:sha256` selector that matches against the SHA-256 hash of the calling binary. Adding `unix:sha256:<hash-of-wrapper>` as a third selector provides defence-in-depth: even if the file at the wrapper path is replaced, the hash mismatch prevents SVID issuance. This does require updating the registration entry whenever the wrapper binary is redeployed. Consider this for the SPIRE Server VM and accounts host where the threat model justifies the operational cost.

Registration entries are version-controlled in `wol-docs/infrastructure/spire-entries.yaml` and applied idempotently via `spire-server entry show` + `spire-server entry create/update`.

### 6.4 vTPM Provisioning CA Bootstrap

The vTPM Provisioning CA is a purpose-specific intermediate CA used only to sign DevID certificates for Proxmox VM vTPMs:

```bash
# Create the Provisioning CA (signed by the WOL offline root)
step certificate create "WOL vTPM Provisioning CA" \
  /etc/wol/pki/vtpm-ca.crt /etc/wol/pki/vtpm-ca.key \
  --profile intermediate-ca \
  --ca /path/to/root_ca.crt --ca-key /path/to/root_ca.key \
  --not-after 8760h    # 1-year lifetime; rotate annually
```

The Provisioning CA cert is loaded into SPIRE Server's `tpm_devid` attestor configuration. **The CA key MUST NOT be stored on the SPIRE Server host.** Storing both the SPIRE intermediate CA key and the Provisioning CA key on the same host would mean a single host compromise yields both -- an attacker could impersonate any VM (via cloned DevID certs) and also issue arbitrary SVIDs. The Provisioning CA key is kept on a separate, dedicated provisioning host that is accessed only during VM provisioning events (via an authenticated, restricted channel). Outside of provisioning windows, the provisioning host is not reachable from the general private network.

Record the Provisioning CA cert fingerprint in `wol-docs/infrastructure/ca-inventory.md` alongside the other CA records.

### 6.5 step-ca Bootstrap (PostgreSQL certs only)

Unchanged from the private-ca proposal for the PostgreSQL client cert exception (Section 5). The step-ca instance issues only `wol` and `wol_migrate` DB client certs. No JWK provisioner is needed -- step-ca issues certs on demand to the migration script, which runs as `wol_migrate`.

---

## Section 7: Configuration Changes

### 7.1 Removed Configuration

The following env vars are removed from all services (replaced by SPIRE):

```
# Removed -- no longer needed
STEP_PROVISIONER_PASSWORD
SECRET_BACKEND
KMS_KEY_ID
BEARER_WINDOW_SECONDS
MAX_NTP_SKEW_SECONDS
NTP_SYNC_TIMEOUT_MINUTES
TLS_CERT          # replaced by SPIRE Workload API
TLS_KEY           # replaced by SPIRE Workload API
TLS_CA_CERT       # replaced by SPIRE trust bundle
```

### 7.2 Added Configuration

```
# SPIRE Workload API socket (same path on all hosts)
SPIFFE_ENDPOINT_SOCKET=unix:///var/run/spire/agent.sock

# JWT-SVID audience (accounts API only -- verifies incoming JWTs against this)
SPIFFE_TRUST_DOMAIN=spiffe://wol
```

### 7.3 Retained Configuration (PostgreSQL DB certs)

```
# step-ca-managed DB client certs -- unchanged
TLS_DB_CERT=/etc/wol/certs/db-client.crt
TLS_DB_KEY=/etc/wol/certs/db-client.key
TLS_DB_CA_CERT=/etc/wol/certs/root_ca.crt
```

---

## Section 8: Ownership Boundaries and Changes to Existing Proposals

### Scope after SPIFFE adoption

This table defines which proposal owns each concern after SPIFFE is adopted. When the two docs appear to conflict, this table is authoritative:

| Concern | Owner after SPIFFE |
|---------|--------------------|
| Offline root CA and its lifecycle | `private-ca-and-secret-management.md` |
| step-ca (PostgreSQL client certs only) | `private-ca-and-secret-management.md` |
| Certificate profiles and TLS policy | `private-ca-and-secret-management.md` |
| Incident response / compromise playbooks | `private-ca-and-secret-management.md` |
| Service-to-service X.509 certificates (SVIDs) | **`spiffe-spire-workload-identity.md`** (this doc) |
| Per-request bearer tokens (JWT-SVIDs) | **`spiffe-spire-workload-identity.md`** (this doc) |
| Master key / bearer HMAC secret | **Removed** -- superseded by JWT-SVIDs |
| Clock skew for bearer tokens | **Removed** -- JWT `exp` handles this |
| Bootstrap provisioner tokens (step-ca) | **Removed** -- superseded by SPIRE node attestation |

Sections 2 (Master Key Management), 3 (Time-Windowed Bearer Secret), and 1.4 (Bootstrap Provisioner) of `private-ca-and-secret-management.md` are superseded by this proposal and should be treated as historical. They describe the pre-SPIRE architecture.

### `private-ca-and-secret-management.md`

| Section | Change |
|---------|--------|
| Scope statement | Add note: after SPIFFE adoption, this proposal governs only the offline root CA, step-ca (DB certs), cert profiles, and playbooks. Service-to-service certs and bearer tokens are governed by this proposal. |
| 1.4 Bootstrap Provisioner | Superseded. Step-ca issues only PostgreSQL DB client certs. All service-to-service certs are issued by SPIRE. |
| 2 Master Key Management | Superseded. KMS/TPM for bearer secrets no longer needed. SPIRE's key manager plugin handles its own CA key. |
| 3 Bearer Secret | Superseded. JWT-SVIDs replace the HMAC scheme. |
| 5 Clock Security | Clock skew for bearer tokens is no longer a concern. NTP hardening remains good practice. |
| 4 Authorization Layer | SPIFFE IDs replace CN-based authorization. Update permission table to use SPIFFE IDs (`spiffe://wol/realm-*` → permitted endpoints). |

### `wol-accounts-db-and-api.md`

| Section | Change |
|---------|--------|
| Bearer secret | `WOL_API_SECRET` and HMAC bearer auth are **pre-SPIRE only**. After SPIFFE adoption: WOL includes a JWT-SVID in `Authorization: Bearer <jwt>` on every request. The accounts API verifies the JWT against the SPIRE trust bundle. Remove `WOL_API_SECRET` and `WOL_ACCOUNTS_API_SECRET` from both sides' configuration. |
| Mutual TLS | After SPIFFE adoption: WOL presents its X.509-SVID from the local SPIRE Agent. The accounts API presents its X.509-SVID. Both sides verify the peer's SVID against the SPIRE trust bundle. |
| WOL Server Changes -- mTLS config | Replace `HttpClientHandler` cert-loading code with SPIRE `X509Source` integration |
| WOL env vars | Replace `WOL_ACCOUNTS_CA_CERT`, `WOL_ACCOUNTS_CLIENT_CERT`, `WOL_ACCOUNTS_CLIENT_KEY`, `WOL_ACCOUNTS_API_SECRET` with `SPIFFE_ENDPOINT_SOCKET` |

---

## Section 9: Affected Repos / Services

| Repo / Service | Change |
|---------------|--------|
| New: `wol-infra` or `wol-docs/infrastructure/` | SPIRE Server configuration, registration entries manifest, bootstrap runbook |
| `wol` | Add `Spiffe.WorkloadApi` NuGet; replace `HttpClientHandler` cert loading with `X509Source`; add `JwtSource` for bearer JWT; remove KMS/HMAC bearer code |
| `wol-accounts` | Add `Spiffe.WorkloadApi` NuGet; replace manual cert loading with `X509Source`; add JWT-SVID verification middleware |
| All hosts | SPIRE Agent installed and running as `systemd` service |
| `wol-docs` | `infrastructure/spire-entries.yaml` (registration manifest), `infrastructure/ca-inventory.md` (SPIRE trust bundle fingerprint) |
| `aicli` CLAUDE.md | Add SPIRE to sub-projects/infrastructure list |

---

## Section 10: Observability and Alerting

SPIRE infrastructure must be actively monitored. Silent failures (SPIRE Server down, agent attestation stale) cause authentication failures that surface only when a service tries to renew an expired SVID.

### 10.1 SPIRE Server Health

- SPIRE Server exposes a health endpoint (`/live` and `/ready`) via its built-in HTTP health port. This is monitored by the existing infrastructure monitoring stack (e.g., Prometheus + Alertmanager, or equivalent).
- Alert when SPIRE Server health check fails for more than 60 seconds -- this starts a 1-hour service SVID countdown for any agent that cannot reach the server.
- Alert when SPIRE Server CA cert is within 48 hours of expiry -- this signals the need for a rotation ceremony (see Section 11).

### 10.2 SPIRE Agent Health

- Each SPIRE Agent exposes a health endpoint. The agent's `systemd` unit is configured with `WatchdogSec` to restart the agent on hang.
- Alert if an agent has not successfully communicated with SPIRE Server for more than 30 minutes.
- Alert if a workload SVID will expire within 15 minutes and the agent has not renewed it (indicates a stuck agent or workload API connectivity problem).

### 10.3 SVID Expiry Monitoring

- Services log the expiry time of their current SVID at startup and after each renewal. The monitoring stack alerts if:
  - Any service SVID expires without renewal (service authentication will fail immediately)
  - Agent SVID expiry is within 4 hours without renewal

### 10.4 SIEM Integration

SPIRE-related security events are forwarded to the same SIEM as the general PKI events (per `private-ca-and-secret-management.md` Section 9.2):

| Event | Severity |
|-------|----------|
| Node attestation succeeded | Info |
| Node attestation failed (unknown DevID or revoked) | Warn |
| Workload attestation failed (UID/path mismatch) | Warn |
| SVID issued or renewed | Info |
| SVID expiry without renewal | Page |
| SPIRE Server CA nearing expiry | Warn |
| Provisioning CA used (new DevID cert issued) | Info |

---

## Section 11: SPIRE CA Rotation Ceremony

The SPIRE intermediate CA (signed by the WOL offline root) has a 1-week lifetime and is renewed automatically by SPIRE. The WOL offline root CA is long-lived and rotated manually. The SPIRE trust bundle (distributed to all agents) is updated automatically when the intermediate CA rotates.

### 11.1 Intermediate CA Rotation (Automatic)

SPIRE Server automatically rotates its intermediate CA before expiry. The new intermediate CA is signed by the same UpstreamAuthority (WOL offline root via `UpstreamAuthority "disk"`). The new trust bundle is pushed to all agents via the bundle endpoint -- no manual intervention required.

### 11.2 WOL Offline Root CA Rotation (Manual, Annual)

When the offline root CA approaches expiry (or if it is compromised), a rotation ceremony is required:

1. **Generate a new offline root CA** on an air-gapped machine using `step certificate create --profile root-ca`
2. **Cross-sign the new root** with the old root: issue a cross-signed cert so that trust chains from either root are valid during the transition
3. **Distribute the new root cert** to all hosts out-of-band (same process as the original bootstrap -- fingerprint verified against the signed inventory in `wol-docs/infrastructure/ca-inventory.md`)
4. **Sign a new SPIRE intermediate CA** from the new root and update the SPIRE Server's `UpstreamAuthority "disk"` configuration
5. **Sign new step-ca intermediate CA** from the new root and restart step-ca
6. **Sign a new vTPM Provisioning CA** from the new root and update SPIRE Server's `tpm_devid` attestor
7. Wait for all SVIDs and DB certs to rotate naturally (within 24 hours) -- services pick up the new chain automatically via the Workload API
8. Remove the old root from trust bundles once all issued certs have rotated
9. Update `wol-docs/infrastructure/ca-inventory.md` with the new root fingerprint (GPG-signed)

### 11.3 SPIRE Trust Bundle Rotation (Propagation Check)

After any CA rotation event, verify that all agents have received the updated trust bundle:
```bash
spire-server bundle show  # shows current bundle
# Check each agent's cached bundle via spire-agent api fetch x509
```

Alert if any agent's cached trust bundle is more than 15 minutes behind the server bundle after a rotation event.

---

## Section 12: Network Controls

The SPIRE control plane is not publicly accessible. The following firewall rules are required:

### 12.1 SPIRE Server

| Source | Destination | Port | Protocol | Purpose |
|--------|-------------|------|----------|---------|
| SPIRE Agent hosts | SPIRE Server | 8081 | TCP | Agent-to-server gRPC (attestation + SVID issuance) |
| Monitoring host | SPIRE Server | 8080 | TCP | Health check endpoint |
| No other source | SPIRE Server | any | any | All other inbound blocked |

The SPIRE Server port (8081) must be reachable only from hosts running a SPIRE Agent. The firewall allowlist is updated when a new VM is provisioned and revoked when a VM is decommissioned.

### 12.2 SPIRE Agent

- The Workload API socket (`/var/run/spire/agent.sock`) is a Unix domain socket -- it is not network-accessible by definition. No firewall rule is required; the OS enforces access via socket permissions (Section 2.1).
- The SPIRE Agent has no inbound network port.

### 12.3 Provisioning Host

The provisioning host (which holds the vTPM Provisioning CA key) is reachable only during active provisioning events:
- Inbound from the Proxmox host running VM provisioning scripts only
- All other inbound blocked
- Ideally, the provisioning host has no persistent inbound network exposure and is brought online only when provisioning is in progress

---

## Section 13: Trade-offs

**Pro:**
- No pre-shared secrets required for workload identity -- eliminates the JWK provisioner problem entirely
- Automatic SVID rotation; zero human interaction after bootstrap
- C# hot-reload works natively via SPIRE SDK's `X509Source` stream -- no `FileSystemWatcher` or `IHttpClientFactory` workarounds
- JWT-SVIDs eliminate the HMAC bearer scheme, master key, clock skew logic, replay cache
- SPIFFE IDs provide cryptographically proven caller identity -- stronger than iss field in a self-signed token
- Scale-out is automatic -- a new host joins after node attestation; no token to generate
- Registration entries are auditable and version-controlled

**Con:**
- SPIRE Server is a new critical dependency -- if unavailable for longer than the SVID lifetime (1h), services cannot renew certs and mTLS fails
- SPIRE Agent must be running on every VM; adds operational surface area
- PostgreSQL client certs remain on step-ca (CN=username constraint); step-ca is not eliminated entirely
- The SPIFFE C# SDK (`Spiffe.WorkloadApi`) adds a new dependency that requires vetting
- SPIRE registration entries must be kept in sync with the actual deployed services; stale entries could deny a legitimate service its SVID
- **vTPM path (Option A):** vTPM state is controlled by the Proxmox host -- a compromised hypervisor could clone a VM's vTPM. VM clone workflows must generate fresh DevID certs, not copy them. Requires a local vTPM Provisioning CA to be bootstrapped.
- **vTPM provisioning hook:** VM clone workflows must generate a fresh DevID cert (not copy the existing one) -- this must be enforced in the Proxmox provisioning process. Cloned VMs with a copied DevID cert are a security violation.
- **Proxmox host trust boundary:** All WOL VMs share Proxmox hypervisor infrastructure. A compromised Proxmox host has access to all VM memory (including in-memory SVIDs and CA key material), virtual disk contents, and vTPM state. The vTPM attestation model is therefore bounded by the security of the Proxmox host itself -- it is not a substitute for physical machine isolation. Mitigation: the SPIRE Server VM must not run on the same Proxmox host as service VMs it certifies; the Proxmox management interface must be locked down and monitored.
- **spire group blast radius:** Any process in the `spire` group on a host can request any SVID registered to that host. Mitigation: one workload per VM. See Section 2.1.
- **LUKS via NBDE (Clevis/Tang):** The SPIRE Server's encrypted disk is unlocked automatically at boot by contacting the Tang server on the `spire-db` host. If Tang is unreachable (e.g., `spire-db` host down), the SPIRE Server VM blocks at initramfs until Tang responds. Boot ordering in Proxmox ensures `spire-db` starts first. A second Tang server on a separate host would eliminate this single dependency.
- **SPIRE ↔ PostgreSQL bootstrap dependency:** SPIRE's own datastore must not use SPIRE-issued certs -- it uses a statically provisioned cert to avoid a circular dependency at startup. See Section 1.4.

---

## Security review response

Responses to findings from `proposals/reviews/infrastructure-proposals-security-review-2026-03-25.md` and `proposals/reviews/infrastructure-proposals-review-followup-2026-03-25.md` that are relevant to this proposal.

| Finding | Status | Resolution |
|---------|--------|------------|
| C5 (one-workload-per-host) | Addressed | Section 2.1 already documents the one-workload-per-VM requirement and the `spire` group blast radius. Additionally addressed in the gateway proposal as a hard normative requirement. Provisioning should fail if more than one workload registration entry exists per host class. |
| H6 (join token leaks via metadata/logging) | Resolved | Section 2.2 updated: tokens are injected via temporary file (mode 0600), never via cloud-init user data, env vars, or CLI args. Post-boot verification script (`ExecStartPost`) confirms no token artifacts remain. Transitional risk eliminated once vTPM attestation is operational. |
| H8 (JWT-SVID replay window) | Resolved | JWT-SVIDs are **pure bearer tokens** (not sender-constrained). Write endpoints require a `jti` claim; the service maintains a TTL-windowed cache of seen `jti` values (window = JWT lifetime, default 5 minutes) and rejects duplicates with `409 Conflict`. Read and health endpoints do not require `jti`. `Authorization` headers must never be logged by any component (enforced via log filter configuration). Specified in `infrastructure/identity-and-auth-contract.md`. |
| H2 (SPIRE availability/DR) | Resolved | SPIRE Server LUKS volume is unlocked automatically at boot via Clevis/Tang NBDE (no operator intervention). Recovery is fully automated: Proxmox restarts VMs, Tang server (on `spire-db` host) comes up first, SPIRE Server unlocks and starts. Services continue on cached SVIDs during the recovery window (up to 1 hour for service SVIDs, 24 hours for agent SVIDs). |
| Followup #2 (SPIFFE ID naming inconsistencies) | Resolved (cross-proposal) | Canonical format is hyphenated flat: `spiffe://wol/realm-a`, `spiffe://wol/server-a`, `spiffe://wol/accounts`. All proposals normalized to this convention. Identity and Auth Contract document will codify the grammar, audience values, and authorization rules. |

Findings addressed in other proposals: C2/M1/M3/M4/M8/M11 (private-ca), C3/C4 (wol-accounts), H3/H4/H5/H7/H9 (wol-gateway), M5/M7/M9/M10 (service proposals), L1-L3 (wol-gateway and cross-cutting).

---

## Out of Scope

- SPIRE federation across trust domains (e.g., WOL ↔ external partner)
- SPIRE active-active HA with multiple simultaneous SPIRE Server instances (warm standby with shared PostgreSQL datastore is in scope -- see Section 1.4)
- Replacing step-ca DB client certs with SPIFFE (requires PostgreSQL SAN-based cert auth -- future work)
- JWT-SVID use as a player-facing authentication token (completely separate concern)
- Kubernetes-based workload attestation (not applicable at current deployment)
