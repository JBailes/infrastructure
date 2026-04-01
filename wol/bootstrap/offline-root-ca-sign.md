# Step 6: Offline Root CA -- Sign Intermediates

Performed on the same **isolated machine** used for step 00.

**Before continuing:** the three intermediate CSRs must already exist on their respective hosts.
This requires that the phase-1 scripts have already run and completed successfully:

```
03-setup-ca.sh           → generates /etc/ca/csr/intermediate.csr       on ca (10.0.0.203)
04-setup-spire-server.sh      → generates /etc/spire/server/intermediate_ca.csr    on spire-server (10.0.0.204)
05-setup-provisioning-host.sh → generates /etc/wol-provisioning/csr/provisioning_ca.csr on provisioning (10.0.0.205)
```

**Tools required:** `openssl`, `gpg`

---

## 1. Sign Intermediate CA CSRs

Collect the three CSRs from the servers:
- `/etc/ca/csr/intermediate.csr` from `ca` (10.0.0.203)
- `/etc/spire/server/intermediate_ca.csr` from `spire-server` (10.0.0.204)
- `/etc/wol-provisioning/csr/provisioning_ca.csr` from `provisioning` (10.0.0.205)

Copy them into `csrs/` on this machine.

```bash
cd /root/wol-pki

# Collect CSRs from each server (run from the isolated machine or a trusted jump host)
scp root@10.0.0.203:/etc/ca/csr/intermediate.csr      csrs/ca-intermediate.csr
scp root@10.0.0.204:/etc/spire/server/intermediate_ca.csr   csrs/spire-intermediate.csr
scp root@10.0.0.205:/etc/wol-provisioning/csr/provisioning_ca.csr csrs/vtpm-provisioning-ca.csr
```

```bash
# Decrypt root CA key for signing session
gpg --decrypt root/wol-root-ca.key.gpg > root/root_ca.key

# --- Sign cfssl intermediate CA ---
openssl x509 -req \
    -in csrs/ca-intermediate.csr \
    -CA root/root_ca.crt \
    -CAkey root/root_ca.key \
    -CAcreateserial \
    -out signed/ca-intermediate.crt \
    -days 1825 \
    -extensions v3_intermediate_ca \
    -extfile <(cat <<EOF
[v3_intermediate_ca]
basicConstraints        = critical,CA:TRUE,pathlen:0
keyUsage                = critical,keyCertSign,cRLSign
subjectKeyIdentifier    = hash
authorityKeyIdentifier  = keyid:always,issuer
EOF
)
openssl x509 -in signed/ca-intermediate.crt -noout -subject -fingerprint -sha256

# --- Sign SPIRE intermediate CA ---
openssl x509 -req \
    -in csrs/spire-intermediate.csr \
    -CA root/root_ca.crt \
    -CAkey root/root_ca.key \
    -CAcreateserial \
    -out signed/spire-intermediate.crt \
    -days 1825 \
    -extensions v3_intermediate_ca \
    -extfile <(cat <<EOF
[v3_intermediate_ca]
basicConstraints        = critical,CA:TRUE,pathlen:0
keyUsage                = critical,keyCertSign,cRLSign
subjectKeyIdentifier    = hash
authorityKeyIdentifier  = keyid:always,issuer
EOF
)
openssl x509 -in signed/spire-intermediate.crt -noout -subject -fingerprint -sha256

# --- Sign vTPM Provisioning CA ---
openssl x509 -req \
    -in csrs/vtpm-provisioning-ca.csr \
    -CA root/root_ca.crt \
    -CAkey root/root_ca.key \
    -CAcreateserial \
    -out signed/vtpm-provisioning-ca.crt \
    -days 1825 \
    -extensions v3_intermediate_ca \
    -extfile <(cat <<EOF
[v3_intermediate_ca]
basicConstraints        = critical,CA:TRUE,pathlen:0
keyUsage                = critical,keyCertSign,cRLSign
subjectKeyIdentifier    = hash
authorityKeyIdentifier  = keyid:always,issuer
EOF
)
openssl x509 -in signed/vtpm-provisioning-ca.crt -noout -subject -fingerprint -sha256

# Re-encrypt and destroy plaintext key
shred -u root/root_ca.key 2>/dev/null || rm root/root_ca.key
echo "Signing complete. Plaintext key destroyed."
```

---

## 2. Distribute Signed Certificates

Transfer from this machine to each server. Use a secure channel (SCP over a trusted network, or physically).

```bash
# root_ca.crt goes to every host
scp root/root_ca.crt  root@10.0.0.203:/etc/ca/certs/root_ca.crt
scp root/root_ca.crt  root@10.0.0.204:/etc/spire/server/root_ca.crt
scp root/root_ca.crt  root@10.0.0.205:/etc/wol-provisioning/root_ca.crt

# Signed intermediates go to their respective hosts
scp signed/ca-intermediate.crt  root@10.0.0.203:/etc/ca/certs/intermediate.crt
scp signed/spire-intermediate.crt    root@10.0.0.204:/etc/spire/server/intermediate_ca.crt
scp signed/vtpm-provisioning-ca.crt  root@10.0.0.205:/etc/wol-provisioning/ca.crt

# root_ca.crt also goes to spire-db, wol-accounts-db, and wol-accounts (for PostgreSQL and SPIRE trust)
scp root/root_ca.crt  root@10.0.0.202:/etc/ssl/wol/root_ca.crt
scp root/root_ca.crt  root@10.0.0.206:/etc/ssl/wol/root_ca.crt
scp root/root_ca.crt  root@10.0.0.207:/etc/ssl/wol/root_ca.crt
```

---

## 3. Update ca-inventory.md

Record all fingerprints in `wol-docs/infrastructure/ca-inventory.md` and GPG-sign the file.

After this step, run the completion scripts on each server:

```
06-complete-ca.sh          on ca (10.0.0.203)
07-complete-spire-server.sh     on spire-server (10.0.0.204)
08-complete-provisioning.sh     on provisioning (10.0.0.205)
```
