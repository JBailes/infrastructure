provider "proxmox" {
  endpoint = var.proxmox_endpoint
  api_token = var.proxmox_api_token
  insecure  = var.proxmox_insecure

  # Some container operations (template import, disk resize) have no API
  # equivalent and the provider shells out over SSH to the node.
  ssh {
    agent    = true
    username = var.proxmox_ssh_user
  }
}
