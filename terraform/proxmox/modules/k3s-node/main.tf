resource "proxmox_virtual_environment_vm" "k3s_node" {
  name      = var.vm_name
  node_name = var.target_node
  vm_id     = var.vm_id
  on_boot   = var.onboot
  tags      = var.tags

  clone {
    vm_id = var.template_vm_id
    full  = true
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

  network_device {
    bridge   = var.bridge
    vlan_id  = var.vlan_tag >= 0 ? var.vlan_tag : null
    firewall = false
  }

  agent {
    enabled = true
  }

  initialization {
    user_account {
      username = var.ci_user
      keys     = [var.ssh_public_key]
    }

    ip_config {
      ipv4 {
        address = var.ip_address
        gateway = var.gateway
      }
    }

    dns {
      servers = split(" ", var.dns_servers)
    }
  }

  lifecycle {
    ignore_changes = [
      initialization[0].user_account[0].password,
    ]
  }
}
