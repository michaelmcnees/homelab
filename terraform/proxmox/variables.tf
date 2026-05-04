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

# --- Talos Image ---

variable "talos_version" {
  description = "Talos Linux version for VM boot media"
  type        = string
  default     = "v1.12.6"
}

variable "talos_iso_url" {
  description = "Talos ISO URL. Override with an Image Factory ISO URL when adding system extensions."
  type        = string
  default     = "https://github.com/siderolabs/talos/releases/download/v1.12.6/metal-amd64.iso"
}

variable "talos_iso_datastore" {
  description = "Shared Proxmox datastore used for the Talos ISO"
  type        = string
  default     = "nfs-isos"
}

variable "talos_iso_file_id" {
  description = "Proxmox file ID for the pre-seeded Talos ISO"
  type        = string
  default     = "nfs-isos:iso/talos-1.12.6-metal-amd64.iso"
}

# --- VM Defaults ---

variable "vm_default_storage" {
  description = "Default storage pool for VM disks"
  type        = string
  default     = "ceph-nvme"
}

variable "kubernetes_vlan_tag" {
  description = "VLAN tag for Kubernetes node VM network interfaces"
  type        = number
  default     = 10
}

# --- LXC Defaults ---

variable "lxc_template_file_id" {
  description = "Proxmox file ID for the Debian LXC template used by service containers."
  type        = string
  default     = "local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst"
}

variable "lxc_default_gateway" {
  description = "Default gateway for service LXCs."
  type        = string
  default     = "10.0.10.1"
}

variable "lxc_dns_servers" {
  description = "DNS servers for service LXCs."
  type        = list(string)
  default     = ["10.0.0.18"]
}

variable "lxc_ssh_public_key_path" {
  description = "Path to the SSH public key installed for root access in service LXCs."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}
