module "registeel" {
  source = "./modules/k3s-node"

  vm_name        = "registeel"
  target_node    = "bulbasaur"
  vm_id          = 112
  cores          = 4
  memory         = 24576
  disk_size      = 50
  storage_pool   = var.vm_default_storage
  ip_address     = "10.0.0.82/24"
  gateway        = var.vm_default_gateway
  dns_servers    = var.vm_dns_servers
  ssh_public_key = var.vm_ssh_public_key
  tags           = ["k3s", "k3s-server", "terraform"]
}
