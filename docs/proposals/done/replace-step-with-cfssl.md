# Replace step-cli/step-ca with cfssl and OpenSSL

## Problem

step-cli and step-ca require the smallstep apt repo or direct downloads from dl.smallstep.com/github.com, both of which have been unreliable (timeouts, 404s). These are the only external binary dependencies that aren't in the standard Debian repos.

## Design

Replace step-cli with `openssl` for CA operations (root CA, intermediate signing, cert inspection). Replace step-ca with `cfssl` for the running CA server that issues short-lived DB client certificates. Both `openssl` and `golang-cfssl` are in the standard Debian 13 repos.

### What changes

| Current | New |
|---------|-----|
| step-cli creates root CA | openssl |
| step-cli signs intermediate CSRs | openssl |
| step-cli inspects/fingerprints certs | openssl |
| step-cli generates JWK provisioner keys | Removed (cfssl uses JSON config) |
| step-ca server on :8443 (bbolt DB, JWK provisioners) | cfssl server on :8443 (JSON config, no database) |
| step-cli enrolls certs via `step ca certificate` | `cfssl` CLI or `curl` to cfssl REST API |
| step-ca renewal daemon | cfssl with longer-lived certs (7 days) + cron renewal |

### cfssl overview

[cfssl](https://github.com/cloudflare/cfssl) is CloudFlare's PKI toolkit. It provides:

- `cfssl serve`: lightweight CA server with REST API
- `cfssl gencert`: generate certs from CSRs
- `cfssl sign`: sign CSRs
- `cfssljson`: parse cfssl JSON output into cert/key files
- JSON-based configuration (no database, no provisioners)
- Standard Debian package: `apt-get install golang-cfssl`

### CA host changes

The `step-ca` host is renamed to `ca`. It runs `cfssl serve` instead of `step-ca`.

**cfssl server config** (`/etc/cfssl/config.json`):
```json
{
  "signing": {
    "default": {
      "expiry": "168h"
    },
    "profiles": {
      "db-client": {
        "usages": ["signing", "key encipherment", "client auth"],
        "expiry": "168h"
      },
      "server": {
        "usages": ["signing", "key encipherment", "server auth"],
        "expiry": "8760h"
      }
    }
  }
}
```

Profiles:
- `db-client`: 7-day certs for PostgreSQL client authentication
- `server`: 1-year certs for TLS server certs (PostgreSQL server, Loki, etc.)

### Certificate enrollment

Services request certs from cfssl via its REST API or CLI:

```bash
# Generate key + CSR
openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
    -keyout client.key -out client.csr -nodes \
    -subj "/CN=wol_world"

# Sign via cfssl REST API
curl -s -X POST http://10.0.0.203:8443/api/v1/cfssl/sign \
    -d "{\"certificate_request\": \"$(cat client.csr)\", \"profile\": \"db-client\"}" \
    | cfssljson -bare client

# Or via cfssl CLI (if cfssl is installed locally)
cfssl sign -ca /path/to/intermediate.crt -ca-key /path/to/intermediate.key \
    -config /path/to/config.json -profile db-client client.csr | cfssljson -bare client
```

### Certificate renewal

A cron job on each service host renews its DB client cert every 3 days (well before the 7-day expiry):

```bash
# /etc/cron.d/cert-renew
0 3 */3 * * root /usr/local/bin/renew-db-cert.sh
```

The renewal script generates a new CSR, sends it to cfssl, writes the new cert, and reloads the service.

### Root CA and intermediate signing

Unchanged in concept, but uses openssl instead of step-cli:

**Root CA creation** (in offline container):
```bash
openssl req -new -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
    -keyout root_ca.key -out root_ca.crt -days 3650 -nodes \
    -subj "/CN=WOL Root CA" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:2" \
    -addext "keyUsage=critical,keyCertSign,cRLSign"
```

**Intermediate CSR signing**:
```bash
openssl x509 -req -in intermediate.csr \
    -CA root_ca.crt -CAkey root_ca.key -CAcreateserial \
    -days 365 -sha256 \
    -extfile <(echo "basicConstraints=critical,CA:TRUE,pathlen:1
keyUsage=critical,keyCertSign,cRLSign") \
    -out intermediate.crt
```

This directly controls pathlen (no more `--set maxPathLen` guessing with step-cli).

### Affected hosts

| Host | Change |
|------|--------|
| step-ca | Renamed to `ca`. Runs cfssl instead of step-ca. |
| Root CA | openssl instead of step-cli. No step-cli install needed. |
| spire-db | No change (PostgreSQL config unchanged) |
| wol-accounts-db | No change (PostgreSQL config unchanged) |
| wol-accounts | `curl` to cfssl API instead of `step ca certificate` |
| wol-world-{prod,test} | Same |
| obs | Same |
| provisioning | Remove step-cli install |

### Bootstrap library changes

Remove:
- `install_step_cli()`

Add:
- `enroll_cert_from_ca()`: generates key + CSR, calls cfssl API, writes cert
- `install_cfssl()`: `apt-get install golang-cfssl` (for hosts that need the CLI)

## Affected Files

- `infrastructure/proxmox/pve-root-ca.sh`: openssl instead of step-cli
- `infrastructure/bootstrap/03-setup-step-ca.sh` -> `03-setup-ca.sh`: cfssl instead of step-ca
- `infrastructure/bootstrap/06-complete-step-ca.sh` -> `06-complete-ca.sh`: cfssl config instead of step-ca ca.json
- `infrastructure/bootstrap/lib/common.sh`: replace install_step_cli with enroll_cert_from_ca
- `infrastructure/bootstrap/05-setup-provisioning-host.sh`: remove step-cli
- `infrastructure/bootstrap/10-setup-wol-accounts.sh`: cfssl enrollment
- `infrastructure/bootstrap/13-setup-wol-world.sh` + prod/test variants
- `infrastructure/bootstrap/17-setup-obs.sh`: cfssl enrollment
- `infrastructure/proxmox/inventory.conf`: rename step-ca to ca
- `infrastructure/bootstrap/00-setup-gateway.sh`: DNS entry rename
- All documentation

## Trade-offs

- cfssl is simpler than step-ca (no database, no provisioners, no ACME)
- 7-day cert lifetime is longer than step-ca's 24h default, but still short-lived
- Cron renewal is less elegant than step-ca's built-in daemon, but works reliably
- Zero external dependencies (golang-cfssl is in Debian repos)
- openssl pathlen control is direct (no `--set maxPathLen` guessing)
- cfssl REST API is unauthenticated by default (acceptable on private network with firewall)
