#!/usr/bin/env bash
# Push a file into a Proxmox VM via the QEMU guest agent, in base64 chunks.
# Used because pve has no SSH key on the VPN gateway and we do not want to
# add one just to run a repair script.
set -euo pipefail

VMID="${1:?usage: push-to-vm.sh <vmid> <localfile> <remotepath>}"
SRC="${2:?}"
DEST="${3:?}"

b64=$(base64 -w0 "$SRC")
tmp="${DEST}.b64"

echo "==> pushing $(stat -c%s "$SRC") bytes to VM ${VMID}:${DEST}"

qm guest exec "$VMID" -- /bin/sh -c ": > ${tmp}" >/dev/null

chunk=1200
total=${#b64}
offset=0
n=0
while [ "$offset" -lt "$total" ]; do
    part="${b64:$offset:$chunk}"
    qm guest exec "$VMID" -- /bin/sh -c "printf '%s' '${part}' >> ${tmp}" >/dev/null
    offset=$((offset + chunk))
    n=$((n + 1))
done
echo "==> wrote ${n} chunks"

qm guest exec "$VMID" -- /bin/sh -c "base64 -d ${tmp} > ${DEST} && chmod 0755 ${DEST} && rm -f ${tmp}" >/dev/null

# Verify the file arrived intact rather than assuming it did.
want=$(sha256sum "$SRC" | awk '{print $1}')
got=$(qm guest exec "$VMID" -- /bin/sh -c "sha256sum ${DEST}" \
      | python3 -c "import sys,json;print(json.load(sys.stdin).get('out-data','').split()[0])")

if [ "$want" = "$got" ]; then
    echo "==> checksum OK: ${got}"
else
    echo "ERROR: checksum mismatch (want ${want}, got ${got})" >&2
    exit 1
fi
