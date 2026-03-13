module "regieleki" {
  source = "./modules/k3s-node"

  vm_name        = "regieleki"
  target_node    = "pikachu"
  vm_id          = 113
  cores          = 2     # Constrained: pikachu shares with LXCs + Pelican VM. May need pod scheduling preferences to avoid overloading.
  memory         = 8192  # 8GB — pikachu needs room for LXCs + Pelican VM
  disk_size      = 50
  storage_pool   = "local-lvm"  # pikachu has no Ceph, use local storage
  ip_address     = "10.0.0.83/24"
  gateway        = var.vm_default_gateway
  dns_servers    = var.vm_dns_servers
  ssh_public_key = var.vm_ssh_public_key
  tags           = ["k3s", "k3s-agent", "terraform"]
}
