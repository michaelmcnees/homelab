module "mariadb" {
  source = "./modules/lxc"

  lxc_hostname     = "mariadb"
  target_node      = "rayquaza"
  lxc_id           = 201
  cores            = 2
  memory           = 4096
  swap             = 1024
  disk_size        = 64
  storage_pool     = var.vm_default_storage
  ip_address       = "10.0.10.91/24"
  gateway          = var.lxc_default_gateway
  dns_servers      = var.lxc_dns_servers
  ssh_public_key   = trimspace(file(pathexpand(var.lxc_ssh_public_key_path)))
  template_file_id = var.lxc_template_file_id
  vlan_tag         = var.kubernetes_vlan_tag
  tags             = ["mariadb", "database", "terraform", "ha"]
  ha_enabled       = true
}
