module "ho_oh" {
  source = "./modules/talos-node"

  vm_name      = "ho-oh"
  target_node  = "latias"
  vm_id        = 144
  cores        = 6
  memory       = 20480
  disk_size    = 100
  storage_pool = var.vm_default_storage
  ip_address   = "10.0.10.15/24"
  vlan_tag     = var.kubernetes_vlan_tag
  tags         = ["talos", "kubernetes", "worker", "terraform"]
}
