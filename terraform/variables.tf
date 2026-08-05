variable "proxmox_endpoint" {
  description = "Proxmox API endpoint, e.g. https://192.168.1.253:8006/"
  type        = string
}

variable "proxmox_api_token" {
  description = "Proxmox API token in the form user@realm!tokenid=uuid"
  type        = string
  sensitive   = true
}

variable "proxmox_insecure" {
  description = "Skip TLS verification (true while the node uses a self-signed cert)"
  type        = bool
  default     = true
}

variable "proxmox_ssh_user" {
  description = "SSH user for provider operations that have no API equivalent"
  type        = string
  default     = "root"
}

variable "node_name" {
  description = "Proxmox node name"
  type        = string
  default     = "pve"
}

# --- Storage and image -----------------------------------------------------

variable "storage" {
  description = "Datastore for container root filesystems"
  type        = string
  default     = "fast"
}

variable "template_file_id" {
  description = "LXC template volume ID"
  type        = string
  default     = "isos:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst"
}

# --- Network ---------------------------------------------------------------

variable "lan_bridge" {
  description = "Bridge carrying the home LAN"
  type        = string
  default     = "vmbr0"
}

variable "ack_bridge" {
  description = "Bridge carrying the ACK private network"
  type        = string
  default     = "vmbr2"
}

variable "lan_cidr" {
  description = "Prefix length of the home LAN"
  type        = number
  default     = 23
}

variable "lan_prefix" {
  description = "First three octets of the LAN. A host's IP is <lan_prefix>.<ctid>."
  type        = string
  default     = "192.168.1"
}

variable "router_gw" {
  description = "Home router / default gateway"
  type        = string
  default     = "192.168.1.1"
}

variable "internal_zone" {
  description = "Internal DNS zone that hosts are registered under"
  type        = string
  default     = "bailes.us"
}

# --- CTID allocation -------------------------------------------------------
#
# CTIDs are assigned sequentially from ctid_start in host_order (see
# hosts.tf), skipping reserved_ctids. A host's address is
# <lan_prefix>.<CTID>, so the CTID *is* the address -- renumbering a host
# moves it.

variable "ctid_start" {
  description = "First CTID to assign. Assignment walks upward from here."
  type        = number
  default     = 101

  validation {
    condition     = var.ctid_start > 0 && var.ctid_start < 240
    error_message = "ctid_start must be below 240; 240-254 belongs to the ACK network."
  }
}

variable "reserved_ctids" {
  description = <<-EOT
    CTIDs that must never be assigned, because something not managed here
    already owns them. The address is taken as well as the ID, since one
    implies the other.

      100  code (this container)
      102  unifi controller
      130-140, 260+  the aimee fleet
  EOT
  type        = list(number)
  default     = [100, 102, 130, 131, 132, 140]
}

# --- DNS registration ------------------------------------------------------

variable "dns_api_token" {
  description = <<-EOT
    Technitium automation token, created by 05-setup-dns.sh and written to
    /etc/dns-api-token on the dns host. Leave empty to skip DNS registration
    (useful on the very first apply, before the dns host exists).
  EOT
  type        = string
  default     = ""
  sensitive   = true
}

variable "ssh_public_key" {
  description = "Public key installed into each container for operator access"
  type        = string
  default     = ""
}
