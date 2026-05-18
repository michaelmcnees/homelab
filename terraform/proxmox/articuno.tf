module "articuno" {
  source = "./modules/talos-node"

  vm_name           = "articuno"
  target_node       = "latios"
  vm_id             = 140
  cores             = 4
  memory            = 10240
  disk_size         = 50
  storage_pool      = var.vm_default_storage
  ip_address        = "10.0.10.11/24"
  talos_iso_file_id = var.talos_iso_file_id
  vlan_tag          = var.kubernetes_vlan_tag
  tags              = ["talos", "kubernetes", "control-plane", "terraform"]
}
