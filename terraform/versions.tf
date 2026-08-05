terraform {
  required_version = ">= 1.6"

  required_providers {
    proxmox = {
      # bpg is the actively maintained Proxmox provider; Telmate's has
      # noticeably rougher LXC support.
      source  = "bpg/proxmox"
      version = "~> 0.66"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}
