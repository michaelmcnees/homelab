# --- Provider Authentication ---

variable "proxmox_endpoint" {
  description = "Proxmox API endpoint URL (e.g., https://10.0.0.x:8006)"
  type        = string
}

variable "proxmox_username" {
  description = "Proxmox API username (e.g., root@pam or terraform@pve!token)"
  type        = string
}

variable "proxmox_password" {
  description = "Proxmox API password or token secret"
  type        = string
  sensitive   = true
}

# --- VM Defaults ---

variable "vm_template_id" {
  description = "Proxmox VM template ID for cloud-init Ubuntu"
  type        = number
  default     = 9000
}

variable "vm_default_storage" {
  description = "Default storage pool for VM disks"
  type        = string
  default     = "ceph-pool"
}

variable "vm_ssh_public_key" {
  description = "SSH public key to inject via cloud-init"
  type        = string
}

variable "vm_default_gateway" {
  description = "Default gateway for VM network"
  type        = string
  default     = "10.0.0.1"
}

variable "vm_dns_servers" {
  description = "DNS servers for VMs"
  type        = string
  default     = "10.0.0.53"
}
