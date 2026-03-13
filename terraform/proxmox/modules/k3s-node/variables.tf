variable "vm_name" {
  description = "VM hostname (e.g., regirock)"
  type        = string
}

variable "target_node" {
  description = "Proxmox node to place this VM on (e.g., charmander)"
  type        = string
}

variable "vm_id" {
  description = "Proxmox VM ID"
  type        = number
}

variable "cores" {
  description = "Number of CPU cores"
  type        = number
  default     = 4
}

variable "memory" {
  description = "RAM in MB"
  type        = number
  default     = 8192
}

variable "disk_size" {
  description = "Boot disk size in GB"
  type        = number
  default     = 50
}

variable "storage_pool" {
  description = "Proxmox storage pool for VM disk"
  type        = string
  default     = "ceph-pool"
}

variable "ip_address" {
  description = "Static IP address (CIDR notation, e.g., 10.0.0.80/24)"
  type        = string
}

variable "gateway" {
  description = "Default gateway IP"
  type        = string
}

variable "dns_servers" {
  description = "DNS server IPs (space-separated)"
  type        = string
}

variable "ssh_public_key" {
  description = "SSH public key for cloud-init user"
  type        = string
}

variable "template_vm_id" {
  description = "VM template ID to clone from"
  type        = number
  default     = 9000
}

variable "ci_user" {
  description = "Cloud-init default user"
  type        = string
  default     = "mcnees"
}

variable "bridge" {
  description = "Network bridge for the VM"
  type        = string
  default     = "vmbr0"
}

variable "vlan_tag" {
  description = "VLAN tag for the VM network interface (-1 for no tag)"
  type        = number
  default     = -1
}

variable "tags" {
  description = "Tags to apply to the VM"
  type        = list(string)
  default     = ["k3s", "terraform"]
}

variable "onboot" {
  description = "Start VM on Proxmox boot"
  type        = bool
  default     = true
}
