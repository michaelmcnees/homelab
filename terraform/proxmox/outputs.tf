output "talos_control_plane_ips" {
  description = "Talos control plane node IPs"
  value = {
    articuno = module.articuno.ip_address
    zapdos   = module.zapdos.ip_address
    moltres  = module.moltres.ip_address
  }
}

output "talos_worker_ips" {
  description = "Talos worker node IPs"
  value = {
    lugia   = module.lugia.ip_address
    "ho-oh" = module.ho_oh.ip_address
  }
}

output "postgresql_lxc_ip" {
  description = "PostgreSQL LXC IP address"
  value       = module.metagross.ip_address
}

output "mariadb_lxc_ip" {
  description = "MariaDB LXC IP address"
  value       = module.mariadb.ip_address
}
