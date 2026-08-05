# Host inventory -- the single source of truth for what exists on the LAN.
#
# Deliberately NOT here: CTIDs and IP addresses. CTIDs are allocated randomly
# (see below) and a host's IP is derived as <lan_prefix>.<ctid>, so addresses
# are an output of provisioning rather than an input to it. That is the whole
# reason the internal DNS zone exists -- nothing should be referring to these
# hosts by address.

locals {
  hosts = {
    apt-cache = {
      cores        = 1
      memory       = 512
      disk         = 32
      privileged   = false
      ack_homed    = true
      description  = "apt-cacher-ng package cache"
    }
    obs = {
      cores        = 2
      memory       = 2048
      disk         = 64
      privileged   = false
      ack_homed    = true
      description  = "Loki + Prometheus + Grafana + Alertmanager"
    }
    nginx-proxy = {
      cores        = 1
      memory       = 256
      disk         = 4
      privileged   = false
      ack_homed    = true
      description  = "nginx reverse proxy + ACME TLS termination"
    }
    personal-web = {
      cores        = 1
      memory       = 256
      disk         = 4
      privileged   = false
      ack_homed    = false
      description  = "Static file server for bailes.us"
    }
    rakuen-web = {
      cores        = 2
      memory       = 1024
      disk         = 8
      privileged   = false
      ack_homed    = false
      description  = "Static file server for rakuensoftware.com"
    }
    bittorrent = {
      cores        = 2
      memory       = 1024
      disk         = 8
      privileged   = true
      ack_homed    = false
      description  = "qBittorrent-nox, routed through the VPN gateway"
    }
    deploy = {
      cores        = 2
      memory       = 2048
      disk         = 32
      privileged   = false
      ack_homed    = true
      description  = "CI/CD deployment container (SSH :2222)"
    }
  }

  # The dns host is provisioned separately (pinned CTID) but still needs to
  # appear in outputs and DNS records alongside the rest.
  dns_ip = "${var.lan_prefix}.${var.dns_ctid}"

  ctids = { for name, _ in local.hosts : name => random_integer.ctid[name].result }
  ips   = { for name, id in local.ctids : name => "${var.lan_prefix}.${id}" }
  fqdns = { for name, _ in local.hosts : name => "${name}.${var.internal_zone}" }
}

# --- CTID allocation -------------------------------------------------------
#
# One independent random draw per host, keyed on the host name, so adding or
# removing a host never disturbs the CTIDs (and therefore the IPs) of the
# others. The alternative -- shuffling a shared pool -- reassigns everything
# whenever the host set changes, which would recreate every container.
#
# The tradeoff is that independent draws can collide. The check below turns a
# collision into a loud plan-time failure rather than two containers silently
# fighting over one ID. If it ever fires, bump the colliding host's `salt`.

variable "ctid_salt" {
  description = "Per-host salt to redraw a CTID, e.g. {obs = 1}. Only needed to break a collision."
  type        = map(number)
  default     = {}
}

resource "random_integer" "ctid" {
  for_each = local.hosts

  min = var.ctid_range_min
  max = var.ctid_range_max

  keepers = {
    name = each.key
    salt = lookup(var.ctid_salt, each.key, 0)
  }
}

# Fail the plan if two hosts drew the same CTID, or if any draw landed on the
# pinned dns CTID.
resource "terraform_data" "ctid_uniqueness" {
  lifecycle {
    precondition {
      condition     = length(distinct(values(local.ctids))) == length(local.ctids)
      error_message = <<-EOT
        Two hosts were allocated the same CTID: ${jsonencode(local.ctids)}
        Set ctid_salt for one of them to redraw, e.g. -var 'ctid_salt={"obs"=1}'.
      EOT
    }
    precondition {
      condition     = !contains(values(local.ctids), var.dns_ctid)
      error_message = "A host drew the pinned dns_ctid (${var.dns_ctid}). Set ctid_salt for it, or move dns_ctid outside the allocation range."
    }
  }

  input = local.ctids
}
