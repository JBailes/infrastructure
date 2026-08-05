# LXC containers.
#
# Terraform provisions the container and its network only. Everything inside
# the guest stays with the bash bootstrap scripts in homelab/bootstrap/ --
# they already encode a lot of hard-won service configuration, and rewriting
# that as Terraform would trade working code for churn.

resource "proxmox_virtual_environment_container" "host" {
  for_each = local.hosts

  node_name = var.node_name
  vm_id     = local.ctids[each.key]

  description   = each.value.description
  tags          = ["homelab", "terraform"]
  unprivileged  = !each.value.privileged
  start_on_boot = true
  started       = true

  initialization {
    hostname = each.key

    ip_config {
      ipv4 {
        address = "${local.ips[each.key]}/${var.lan_cidr}"
        # bittorrent egresses via the VPN gateway, never the router directly.
        gateway = each.key == "bittorrent" ? local.vpn_gateway_ip : var.router_gw
      }
    }

    # Point every guest at the internal resolver so the bootstrap scripts can
    # address each other by name.
    dns {
      domain  = var.internal_zone
      servers = [local.dns_ip]
    }

    dynamic "user_account" {
      for_each = var.ssh_public_key == "" ? [] : [1]
      content {
        keys = [var.ssh_public_key]
      }
    }
  }

  cpu {
    cores = each.value.cores
  }

  memory {
    dedicated = each.value.memory
  }

  disk {
    datastore_id = var.storage
    size         = each.value.disk
  }

  operating_system {
    template_file_id = var.template_file_id
    type             = "debian"
  }

  network_interface {
    name   = "eth0"
    bridge = var.lan_bridge
  }

  # Hosts that also serve the ACK network get a second NIC. The ACK side is
  # addressed statically because that network has no internal DNS of its own.
  dynamic "network_interface" {
    for_each = each.value.ack_homed ? [1] : []
    content {
      name   = "eth1"
      bridge = var.ack_bridge
    }
  }

  features {
    nesting = true
  }

  lifecycle {
    # The bootstrap scripts install packages and write config inside the
    # guest; never let a template change silently recreate a live host.
    ignore_changes = [operating_system]
  }
}

locals {
  # The VPN gateway is a VM managed outside this module (see below).
  vpn_gateway_ip = "${var.lan_prefix}.104"
}
