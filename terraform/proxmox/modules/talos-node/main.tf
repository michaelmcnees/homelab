resource "proxmox_virtual_environment_vm" "talos_node" {
  name      = var.vm_name
  node_name = var.target_node
  vm_id     = var.vm_id
  on_boot   = var.onboot
  started   = var.started
  tags      = var.tags

  bios          = "seabios"
  boot_order    = ["scsi0", "ide2"]
  machine       = "q35"
  scsi_hardware = "virtio-scsi-single"

  operating_system {
    type = "l26"
  }

  cpu {
    cores = var.cores
    type  = "host"
  }

  memory {
    dedicated = var.memory
  }

  disk {
    datastore_id = var.storage_pool
    interface    = "scsi0"
    size         = var.disk_size
    discard      = "on"
    ssd          = true
  }

  cdrom {
    file_id   = var.talos_iso_file_id
    interface = "ide2"
  }

  network_device {
    bridge   = var.bridge
    vlan_id  = var.vlan_tag >= 0 ? var.vlan_tag : null
    firewall = false
  }

  serial_device {
    device = "socket"
  }

  vga {
    type   = "std"
    memory = 16
  }
}
