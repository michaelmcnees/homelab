output "vm_id" {
  description = "Proxmox VM ID"
  value       = proxmox_virtual_environment_vm.k3s_node.vm_id
}

output "vm_name" {
  description = "VM hostname"
  value       = proxmox_virtual_environment_vm.k3s_node.name
}

output "ip_address" {
  description = "VM IP address"
  value       = var.ip_address
}
