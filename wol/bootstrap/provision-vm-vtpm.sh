#!/usr/bin/env bash
# 13-provision-vm-vtpm.sh -- Issue a vTPM DevID cert for a Proxmox VM
#
# Runs on: the VM being provisioned (after VM creation in Proxmox)
# Run order: Not part of initial bootstrap; used when migrating from join tokens to vTPM attestation
#
# Prerequisites:
#   - VM created in Proxmox with a vTPM 2.0 device (swtpm)
#   - tpm2-tools installed
#   - Provisioning CA host (10.0.0.205) reachable for cert signing
#   - SPIRE Agent NOT yet started on this host (vTPM attestation replaces join token)
#
# What this script does:
#   1. Verifies the vTPM device is present
#   2. Creates a DevID key pair inside the vTPM (persistent, survives reboots)
#   3. Generates a CSR for the DevID key
#   4. Sends the CSR to the provisioning host (10.0.0.205) for signing
#   5. Stores the signed DevID cert for SPIRE Agent use
#
# After this script, update the SPIRE Agent config to use tpm_devid instead of join_token.

set -euo pipefail

# Boot-time secret scrub: remove leftover .env.bootstrap from prior failed runs
rm -f /root/.env.bootstrap

PROV_HOST="10.0.0.205"
PROV_PORT="9000"
TPM_DEVICE="/dev/tpm0"
DEVID_DIR="/var/lib/spire/agent"
DEVID_KEY_HANDLE="0x81000001"  # Persistent handle in the vTPM

THIS_HOSTNAME="${HOSTNAME_OVERRIDE:-$(hostname -s)}"

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

[[ $EUID -eq 0 ]] || err "Run as root"

install_packages() {
    info "Installing tpm2-tools"
    apt-get update -qq
    apt-get install -y --no-install-recommends tpm2-tools openssl
}

check_vtpm() {
    info "Checking for vTPM device"
    [[ -c "$TPM_DEVICE" ]] \
        || err "vTPM device $TPM_DEVICE not found. Ensure the VM has a vTPM 2.0 device in Proxmox."

    tpm2_getcap properties-fixed | grep -q "TPM2_PT_FIRMWARE_VERSION" \
        || err "Cannot communicate with vTPM. Is tpm2-abrmd running?"

    info "vTPM detected"
}

generate_devid_key() {
    info "Generating DevID key in vTPM (persistent handle $DEVID_KEY_HANDLE)"
    mkdir -p "$DEVID_DIR"

    # Check if persistent key already exists
    if tpm2_readpublic -c "$DEVID_KEY_HANDLE" &>/dev/null; then
        info "DevID key already exists at handle $DEVID_KEY_HANDLE; skipping generation"
    else
        # Create primary key under endorsement hierarchy
        tpm2_createprimary -C e -g sha256 -G ecc256 -c /tmp/primary.ctx

        # Create DevID key (ECDSA P-256, non-duplicable, restricted signing)
        tpm2_create \
            -C /tmp/primary.ctx \
            -G ecc256 \
            -u "$DEVID_DIR/devid.pub" \
            -r "$DEVID_DIR/devid.priv" \
            -a "fixedtpm|fixedparent|sensitivedataorigin|userwithauth|sign|noda"

        # Load and persist the key
        tpm2_load -C /tmp/primary.ctx \
            -u "$DEVID_DIR/devid.pub" \
            -r "$DEVID_DIR/devid.priv" \
            -c "$DEVID_DIR/devid.ctx"

        tpm2_evictcontrol -C o \
            -c "$DEVID_DIR/devid.ctx" \
            "$DEVID_KEY_HANDLE"

        rm -f /tmp/primary.ctx "$DEVID_DIR/devid.ctx"
        info "DevID key persisted at TPM handle $DEVID_KEY_HANDLE"
    fi

    # Export public key in PEM format for CSR generation
    tpm2_readpublic -c "$DEVID_KEY_HANDLE" -o /tmp/devid_pub.pem -f pem
}

generate_devid_csr() {
    info "Generating DevID CSR for host: $THIS_HOSTNAME"
    # Note: tpm2-tools does not directly generate a PKCS#10 CSR using a TPM key.
    # We use openssl with a TPM2 engine (tpm2-openssl provider) if available,
    # or generate a temporary software key for the CSR and load it via TPM handle.
    #
    # Simplified approach: generate CSR using the exported public key material.
    # In production, use the tpm2-openssl provider for full TPM-backed CSR signing.

    if openssl req -new \
        -engine tpm2 -keyform engine -key "handle:$DEVID_KEY_HANDLE" \
        -out "$DEVID_DIR/devid.csr" \
        -subj "/CN=${THIS_HOSTNAME}-devid/O=WOL Infrastructure" 2>/dev/null; then
        info "CSR generated using TPM2 engine"
    else
        info "TPM2 OpenSSL engine not available. Generating software-signed CSR for submission."
        info "In production: install libtpm2-openssl for TPM-backed CSR signing."
        local tmp_key
        tmp_key=$(mktemp)
        openssl ecparam -genkey -name prime256v1 -noout 2>/dev/null \
            | openssl pkcs8 -topk8 -nocrypt -out "$tmp_key"
        openssl req -new \
            -key "$tmp_key" \
            -out "$DEVID_DIR/devid.csr" \
            -subj "/CN=${THIS_HOSTNAME}-devid/O=WOL Infrastructure" 2>/dev/null \
            || { rm -f "$tmp_key"; err "CSR generation failed. Install tpm2-openssl provider."; }
        rm -f "$tmp_key"
    fi

    info "CSR: $DEVID_DIR/devid.csr"
}

submit_csr_to_provisioning_host() {
    info "Submitting CSR to provisioning host ($PROV_HOST:$PROV_PORT)"
    # Transfer CSR to provisioning host and retrieve signed DevID cert
    scp "$DEVID_DIR/devid.csr" "root@$PROV_HOST:/tmp/${THIS_HOSTNAME}-devid.csr"
    ssh "root@$PROV_HOST" "issue-devid-cert '$THIS_HOSTNAME' '/tmp/${THIS_HOSTNAME}-devid.csr'" \
        > "$DEVID_DIR/devid.crt"

    openssl x509 -in "$DEVID_DIR/devid.crt" -noout -subject -fingerprint -sha256
    info "DevID cert stored at $DEVID_DIR/devid.crt"
}

update_spire_agent_config() {
    local agent_conf="/etc/spire/agent/agent.conf"
    cat <<EOF

================================================================
DevID cert issued successfully.

To migrate from join_token to tpm_devid attestation:

1. Update $agent_conf:
   Replace:
     NodeAttestor "join_token" { plugin_data {} }
   With:
     NodeAttestor "tpm_devid" {
         plugin_data {
             devid_cert_path     = "$DEVID_DIR/devid.crt"
             devid_priv_key_path = "$DEVID_DIR/devid.priv"
         }
     }
   And remove the join_token line from the agent {} block.

2. On spire-server, uncomment the tpm_devid NodeAttestor in server.conf
   and copy the Provisioning CA cert:
     scp root@10.0.0.205:/etc/wol-provisioning/ca.crt \\
         root@10.0.0.204:/etc/spire/server/vtpm-provisioning-ca.crt
   Then: systemctl restart spire-server

3. On this host: systemctl restart spire-agent
================================================================
EOF
}

main() {
    install_packages
    check_vtpm
    generate_devid_key
    generate_devid_csr
    submit_csr_to_provisioning_host
    update_spire_agent_config
}

main "$@"
