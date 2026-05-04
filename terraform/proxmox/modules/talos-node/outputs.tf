output "vm_id" {
  description = "Created VM ID."
  value       = proxmox_virtual_environment_vm.talos_node.vm_id
}

output "name" {
  description = "Created VM name."
  value       = proxmox_virtual_environment_vm.talos_node.name
}

output "ip_address" {
  description = "Static Talos node IP in CIDR notation."
  value       = var.ip_address
}
