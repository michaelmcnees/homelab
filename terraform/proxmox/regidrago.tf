module "regidrago" {
  source = "./modules/k3s-node"

  vm_name        = "regidrago"
  target_node    = "snorlax"
  vm_id          = 114
  cores          = 4
  memory         = 16384  # 16GB — snorlax has 64GB, ~32GB to TrueNAS VM, rest here + overhead
  disk_size      = 50
  storage_pool   = "local-lvm"  # Use snorlax local storage; Ceph is on the Dell nodes
  ip_address     = "10.0.0.84/24"
  gateway        = var.vm_default_gateway
  dns_servers    = var.vm_dns_servers
  ssh_public_key = var.vm_ssh_public_key
  tags           = ["k3s", "k3s-agent", "terraform"]
}
