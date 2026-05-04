variable "vm_name" {
  description = "VM hostname."
  type        = string
}

variable "target_node" {
  description = "Proxmox node to place this VM on."
  type        = string
}

variable "vm_id" {
  description = "Proxmox VM ID."
  type        = number
}

variable "cores" {
  description = "Number of CPU cores."
  type        = number
  default     = 4
}

variable "memory" {
  description = "RAM in MB."
  type        = number
  default     = 8192
}

variable "disk_size" {
  description = "Boot disk size in GB."
  type        = number
  default     = 50
}

variable "storage_pool" {
  description = "Proxmox storage pool for VM disk."
  type        = string
  default     = "ceph-nvme"
}

variable "ip_address" {
  description = "Static Talos node IP in CIDR notation; used for repo outputs and talosctl tasks."
  type        = string
}

variable "talos_iso_file_id" {
  description = "Proxmox file ID for the Talos ISO attached to this VM."
  type        = string
}

variable "bridge" {
  description = "Network bridge for the VM."
  type        = string
  default     = "vmbr0"
}

variable "vlan_tag" {
  description = "VLAN tag for the VM network interface (-1 for no tag)."
  type        = number
  default     = -1
}

variable "tags" {
  description = "Tags to apply to the VM."
  type        = list(string)
  default     = ["talos", "kubernetes", "terraform"]
}

variable "onboot" {
  description = "Start VM on Proxmox boot."
  type        = bool
  default     = true
}

variable "started" {
  description = "Start VM after creation."
  type        = bool
  default     = true
}
