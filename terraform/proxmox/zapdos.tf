module "zapdos" {
  source = "./modules/talos-node"

  vm_name           = "zapdos"
  target_node       = "latias"
  vm_id             = 141
  cores             = 4
  memory            = 10240
  disk_size         = 50
  storage_pool      = var.vm_default_storage
  ip_address        = "10.0.10.12/24"
  talos_iso_file_id = var.talos_iso_file_id
  vlan_tag          = var.kubernetes_vlan_tag
  tags              = ["talos", "kubernetes", "control-plane", "terraform"]
}
