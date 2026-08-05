#!/usr/bin/env python3
"""Swap the random-CTID variables for the sequential scheme."""

P = "terraform/variables.tf"
s = open(P).read()

start = s.index("# --- CTID allocation ---")
end = s.index("# --- DNS registration ---")

NEW = '''# --- CTID allocation -------------------------------------------------------
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

'''

s = s[:start] + NEW + s[end:]

# dns_ctid was inside the replaced block: dns is now simply first in
# host_order, so there is no separate pin to remove.
assert 'variable "dns_ctid"' not in s, "dns_ctid survived the replacement"

open(P, "w").write(s)
print("variables.tf: sequential CTID scheme")
