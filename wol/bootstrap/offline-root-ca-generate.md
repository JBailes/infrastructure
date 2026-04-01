# Step 1: Offline Root CA -- Generate Root CA (Session A)

Performed on an **isolated machine** (VM with no network access, or a dedicated host).
Nothing from this process touches the production network.

Run this before any servers are provisioned. After completing steps 1-3 here,
run scripts 02-05 on their respective hosts to generate intermediate CSRs, then
return to the isolated machine and follow **06-offline-root-ca-sign.md** (Session B).

**Tools required:** `openssl`, `gpg`

---

## 1. Environment

Set up on any Debian 13 machine. Remove all network interfaces or block all outbound traffic before proceeding.

```bash
apt-get install -y openssl gpg

mkdir -p /root/wol-pki/{root,csrs,signed}
cd /root/wol-pki
```

---

## 2. Generate Root CA

```bash
# Generate ECDSA P-256 root CA key
openssl ecparam -genkey -name prime256v1 -noout \
    | openssl pkcs8 -topk8 -nocrypt -out root/root_ca.key

# Generate self-signed root CA certificate (10-year lifetime)
openssl req -new -x509 \
    -key root/root_ca.key \
    -out root/root_ca.crt \
    -days 3650 \
    -subj "/CN=WOL Offline Root CA/O=WOL Infrastructure" \
    -extensions v3_ca \
    -config <(cat /etc/ssl/openssl.cnf; echo -e "\n[v3_ca]\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid:always,issuer")

# Verify
openssl x509 -in root/root_ca.crt -noout -text | grep -E "Subject:|Not (Before|After)|Public Key"

# Record fingerprint in ca-inventory.md
openssl x509 -in root/root_ca.crt -noout -fingerprint -sha256
```

---

## 3. Encrypt Root CA Key (Digital Storage)

```bash
# Encrypt root CA key with GPG symmetric encryption (AES-256)
# You will be prompted for a passphrase. Use a strong, unique passphrase.
# Record it in your team's secure credential store (e.g. Bitwarden, 1Password, Vault)
gpg --symmetric --cipher-algo AES256 --armor \
    --output root/wol-root-ca.key.gpg \
    root/root_ca.key

# Verify the encrypted backup can be decrypted
gpg --decrypt root/wol-root-ca.key.gpg > /dev/null && echo "Decrypt OK"

# Store wol-root-ca.key.gpg in TWO separate secure digital locations
# (e.g., separate encrypted vaults, offline VMs, or team secret stores)
# DO NOT store it on any production host

# Securely delete the plaintext key once encrypted backup is verified
# (shred requires the file to be on a physical disk; for tmpfs/virtual disk, truncate is sufficient)
shred -u root/root_ca.key 2>/dev/null || {
    dd if=/dev/zero of=root/root_ca.key bs=1 count=$(wc -c < root/root_ca.key) conv=notrunc
    rm root/root_ca.key
}

echo "Root CA key encrypted. Distribute wol-root-ca.key.gpg to secure storage."
```

> **Decrypting when needed for signing:**
> ```bash
> gpg --decrypt wol-root-ca.key.gpg > root_ca.key
> # ... perform signing operations ...
> shred -u root_ca.key
> ```

---

---

After completing steps 1-3 above, proceed to run scripts 02-05 on their respective hosts,
then continue with **06-offline-root-ca-sign.md** on this machine.
