output "k3s_server_ips" {
  description = "K3s control plane node IPs"
  value = {
    regirock  = module.regirock.ip_address
    regice    = module.regice.ip_address
    registeel = module.registeel.ip_address
  }
}

output "k3s_agent_ips" {
  description = "K3s worker node IPs"
  value = {
    regieleki = module.regieleki.ip_address
    regidrago = module.regidrago.ip_address
  }
}
