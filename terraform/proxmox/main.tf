locals {
  proxmox_uses_api_token = strcontains(var.proxmox_username, "!")
}

provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  username  = local.proxmox_uses_api_token ? null : var.proxmox_username
  password  = local.proxmox_uses_api_token ? null : var.proxmox_password
  api_token = local.proxmox_uses_api_token ? "${var.proxmox_username}=${var.proxmox_password}" : null
  insecure  = true # Self-signed certs on Proxmox

  ssh {
    agent = true
  }
}
