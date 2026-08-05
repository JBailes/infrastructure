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
# CTIDs are allocated randomly rather than hand-assigned, and a host's IP is
# derived from its CTID (<lan_prefix>.<ctid>). The range must therefore stay
# inside the LAN's usable host range and clear of anything not managed here.

variable "ctid_range_min" {
  description = "Lowest CTID that may be allocated"
  type        = number
  default     = 150
}

variable "ctid_range_max" {
  description = "Highest CTID that may be allocated. Keep below the ACK range (240-254)."
  type        = number
  default     = 239

  validation {
    condition     = var.ctid_range_max < 240
    error_message = "ctid_range_max must stay below 240; 240-254 belongs to the ACK network."
  }
}

variable "dns_ctid" {
  description = <<-EOT
    CTID for the dns host. This one is pinned rather than random: it is the
    bootstrap floor, so every other host needs a predictable address to point
    --nameserver at before name resolution exists. Must be outside
    [ctid_range_min, ctid_range_max] so it can never collide with an
    allocated one.
  EOT
  type        = number
  default     = 149

  validation {
    condition     = var.dns_ctid > 0 && var.dns_ctid < 255
    error_message = "dns_ctid must be a valid last octet (1-254)."
  }
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
