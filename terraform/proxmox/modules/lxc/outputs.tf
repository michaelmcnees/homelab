output "id" {
  description = "Proxmox LXC VMID."
  value       = proxmox_virtual_environment_container.lxc.vm_id
}

output "hostname" {
  description = "LXC hostname."
  value       = var.lxc_hostname
}

output "ip_address" {
  description = "LXC IP address in CIDR notation."
  value       = var.ip_address
}
