# Host inventory -- the single source of truth for what Terraform provisions.
#
# CTIDs are assigned SEQUENTIALLY from ctid_start, in the order below, and a
# host's address is 192.168.1.<CTID>. Reserved IDs are skipped, so the
# assignment stays dense without ever landing on a guest that is not managed
# here.
#
# This must agree with the CTID_* block in homelab/bootstrap/lib/common.sh --
# the bash scripts create the same containers when Terraform is not used.

locals {
  # Order matters: it determines CTID assignment. Append new hosts at the end
  # so existing ones keep their IDs. Inserting into the middle renumbers
  # everything after it, which means recreating those containers.
  host_order = [
    "dns",
    "apt-cache",
    "obs",
    "nginx-proxy",
    "personal-web",
    "rakuen-web",
    "bittorrent",
    "deploy",
  ]

  hosts = {
    dns = {
      cores       = 2
      memory      = 1024
      disk        = 8
      privileged  = false
      ack_homed   = false
      ack_ip      = null
      description = "Technitium DNS, authoritative for the internal zone"
    }
    apt-cache = {
      cores       = 1
      memory      = 512
      disk        = 32
      privileged  = false
      ack_homed   = true
      ack_ip      = "10.1.0.115"
      description = "apt-cacher-ng package cache"
    }
    obs = {
      cores       = 2
      memory      = 2048
      disk        = 64
      privileged  = false
      ack_homed   = true
      ack_ip      = "10.1.0.100"
      description = "Loki + Prometheus + Grafana + Alertmanager"
    }
    nginx-proxy = {
      cores       = 1
      memory      = 256
      disk        = 4
      privileged  = false
      ack_homed   = true
      ack_ip      = "10.1.0.118"
      description = "nginx reverse proxy + ACME TLS termination"
    }
    personal-web = {
      cores       = 1
      memory      = 256
      disk        = 4
      privileged  = false
      ack_homed   = false
      ack_ip      = null
      description = "Static file server for bailes.us"
    }
    rakuen-web = {
      cores       = 2
      memory      = 1024
      disk        = 8
      privileged  = false
      ack_homed   = false
      ack_ip      = null
      description = "Static file server for rakuensoftware.com"
    }
    bittorrent = {
      cores       = 2
      memory      = 1024
      disk        = 8
      privileged  = true
      ack_homed   = false
      ack_ip      = null
      description = "qBittorrent-nox, routed through the VPN gateway"
    }
    deploy = {
      cores       = 2
      memory      = 2048
      disk        = 32
      privileged  = false
      ack_homed   = true
      ack_ip      = "10.1.0.101"
      description = "CI/CD deployment container (SSH :2222)"
    }
  }

  # Sequential assignment: walk upward from ctid_start, skipping reserved IDs.
  # Taking as many candidates as there are hosts keeps this dense.
  candidate_ctids = [
    for i in range(var.ctid_start, var.ctid_start + 200) : i
    if !contains(var.reserved_ctids, i)
  ]

  ctids = {
    for idx, name in local.host_order : name => local.candidate_ctids[idx]
  }

  ips   = { for name, id in local.ctids : name => "${var.lan_prefix}.${id}" }
  fqdns = { for name, _ in local.hosts : name => "${name}.${var.internal_zone}" }

  # The VPN gateway is a VM created by 01-setup-vpn-gateway.sh, not managed
  # here, but it still needs a DNS record. It takes the next ID after the
  # containers.
  vpn_gateway_ctid = local.candidate_ctids[length(local.host_order)]
  vpn_gateway_ip   = "${var.lan_prefix}.${local.vpn_gateway_ctid}"

  dns_ip = local.ips["dns"]
}

# Guard the invariants rather than trusting the arithmetic.
resource "terraform_data" "ctid_invariants" {
  lifecycle {
    precondition {
      condition     = length(local.host_order) == length(local.hosts)
      error_message = "host_order and hosts disagree: ${jsonencode(setsubtract(keys(local.hosts), local.host_order))} missing from host_order."
    }
    precondition {
      condition     = length(distinct(values(local.ctids))) == length(local.ctids)
      error_message = "Duplicate CTID assigned: ${jsonencode(local.ctids)}"
    }
    precondition {
      condition     = alltrue([for id in values(local.ctids) : id < 240])
      error_message = "A CTID landed at 240 or above, which belongs to the ACK network: ${jsonencode(local.ctids)}"
    }
    precondition {
      condition     = !contains(values(local.ctids), local.vpn_gateway_ctid)
      error_message = "The VPN gateway CTID collides with a container."
    }
  }

  input = local.ctids
}
