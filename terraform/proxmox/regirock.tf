module "regirock" {
  source = "../modules/k3s-node"

  vm_name        = "regirock"
  target_node    = "charmander"
  vm_id          = 110
  cores          = 4
  memory         = 24576  # 24GB — leaves ~8GB for Proxmox + Ceph on 32GB host
  disk_size      = 50
  storage_pool   = var.vm_default_storage
  ip_address     = "10.0.0.80/24"
  gateway        = var.vm_default_gateway
  dns_servers    = var.vm_dns_servers
  ssh_public_key = var.vm_ssh_public_key
  tags           = ["k3s", "k3s-server", "terraform"]
}
