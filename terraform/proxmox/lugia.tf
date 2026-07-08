module "lugia" {
  source = "./modules/talos-node"

  vm_name      = "lugia"
  target_node  = "latios"
  vm_id        = 143
  cores        = 8
  memory       = 40960
  disk_size    = 200
  storage_pool = var.vm_default_storage
  ip_address   = "10.0.10.14/24"
  vlan_tag     = var.kubernetes_vlan_tag
  tags         = ["talos", "kubernetes", "worker", "terraform"]
}
