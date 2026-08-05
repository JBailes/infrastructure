# Internal DNS registration.
#
# There is no maintained Terraform provider for Technitium, so records are
# written through its HTTP API. Each record is its own resource keyed on the
# host name, so a changed IP re-registers only that host.
#
# Registration is idempotent (overwrite=true), which makes this double as a
# repair step: re-applying re-asserts every record.
#
# Skipped entirely when dns_api_token is empty -- on the very first apply the
# dns host does not exist yet, so there is nothing to register against.

locals {
  dns_enabled = var.dns_api_token != ""

  # Everything that should resolve inside the zone, including the dns host
  # itself and the VPN gateway (a VM, not managed as a container here).
  dns_records = merge(
    local.ips,
    {
      dns         = local.dns_ip
      vpn-gateway = local.vpn_gateway_ip
    },
  )
}

resource "terraform_data" "dns_record" {
  for_each = local.dns_enabled ? local.dns_records : {}

  # Re-run when the name or address changes.
  input = {
    fqdn = "${each.key}.${var.internal_zone}"
    ip   = each.value
  }

  triggers_replace = {
    fqdn = "${each.key}.${var.internal_zone}"
    ip   = each.value
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      DNS_TOKEN = var.dns_api_token
    }
    command = <<-EOT
      set -euo pipefail
      response=$(curl -sf -G "http://${local.dns_ip}:5380/api/zones/records/add" \
        --data-urlencode "token=$DNS_TOKEN" \
        --data-urlencode "zone=${var.internal_zone}" \
        --data-urlencode "domain=${each.key}.${var.internal_zone}" \
        --data-urlencode "type=A" \
        --data-urlencode "ipAddress=${each.value}" \
        --data-urlencode "ttl=300" \
        --data-urlencode "overwrite=true")
      # A non-ok status still returns HTTP 200, so inspect the body.
      if ! grep -q '"status":"ok"' <<<"$response"; then
        echo "DNS registration failed for ${each.key}: $response" >&2
        exit 1
      fi
      echo "registered ${each.key}.${var.internal_zone} -> ${each.value}"
    EOT
  }

  depends_on = [proxmox_virtual_environment_container.host]
}
