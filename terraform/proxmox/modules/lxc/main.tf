resource "proxmox_virtual_environment_container" "lxc" {
  node_name     = var.target_node
  vm_id         = var.lxc_id
  description   = "Managed by OpenTofu"
  tags          = var.tags
  started       = var.started
  start_on_boot = var.start_on_boot
  unprivileged  = var.unprivileged

  initialization {
    hostname = var.lxc_hostname

    dns {
      servers = var.dns_servers
    }

    ip_config {
      ipv4 {
        address = var.ip_address
        gateway = var.gateway
      }
    }

    user_account {
      keys = [var.ssh_public_key]
    }
  }

  cpu {
    cores = var.cores
  }

  memory {
    dedicated = var.memory
    swap      = var.swap
  }

  disk {
    datastore_id = var.storage_pool
    size         = var.disk_size
  }

  operating_system {
    template_file_id = var.template_file_id
    type             = var.os_type
  }

  network_interface {
    name     = "eth0"
    bridge   = var.bridge
    vlan_id  = var.vlan_tag >= 0 ? var.vlan_tag : null
    firewall = false
  }

  features {
    nesting = true
  }

  lifecycle {
    ignore_changes = [
      node_name,
    ]
  }
}

resource "proxmox_virtual_environment_haresource" "lxc" {
  count = var.ha_enabled ? 1 : 0

  resource_id = "ct:${proxmox_virtual_environment_container.lxc.vm_id}"
  group       = var.ha_group
  state       = "started"
  comment     = "Managed by OpenTofu"
}
