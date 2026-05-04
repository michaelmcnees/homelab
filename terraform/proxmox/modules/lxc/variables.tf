variable "lxc_hostname" {
  description = "LXC container hostname."
  type        = string
}

variable "target_node" {
  description = "Proxmox node to place the LXC on."
  type        = string
}

variable "lxc_id" {
  description = "Proxmox VMID for the LXC."
  type        = number
}

variable "cores" {
  description = "Number of CPU cores."
  type        = number
  default     = 2
}

variable "memory" {
  description = "Dedicated memory in MB."
  type        = number
  default     = 2048
}

variable "swap" {
  description = "Swap memory in MB."
  type        = number
  default     = 512
}

variable "disk_size" {
  description = "Root disk size in GB."
  type        = number
  default     = 20
}

variable "storage_pool" {
  description = "Storage pool for the LXC root disk."
  type        = string
}

variable "ip_address" {
  description = "Static IPv4 address in CIDR notation."
  type        = string
}

variable "gateway" {
  description = "Default IPv4 gateway."
  type        = string
}

variable "dns_servers" {
  description = "DNS servers for the container."
  type        = list(string)
}

variable "ssh_public_key" {
  description = "SSH public key for root access."
  type        = string
}

variable "template_file_id" {
  description = "Proxmox LXC template file ID."
  type        = string
}

variable "os_type" {
  description = "Container OS type."
  type        = string
  default     = "debian"
}

variable "bridge" {
  description = "Network bridge for the LXC."
  type        = string
  default     = "vmbr0"
}

variable "vlan_tag" {
  description = "VLAN tag for the LXC network interface (-1 for no tag)."
  type        = number
  default     = -1
}

variable "tags" {
  description = "Tags to apply to the LXC."
  type        = list(string)
  default     = ["lxc", "terraform"]
}

variable "start_on_boot" {
  description = "Start LXC on Proxmox boot."
  type        = bool
  default     = true
}

variable "started" {
  description = "Start LXC after creation."
  type        = bool
  default     = true
}

variable "unprivileged" {
  description = "Create the LXC as an unprivileged container."
  type        = bool
  default     = true
}

variable "ha_enabled" {
  description = "Manage this LXC as a Proxmox HA resource."
  type        = bool
  default     = false
}

variable "ha_group" {
  description = "Optional Proxmox HA group."
  type        = string
  default     = null
}
