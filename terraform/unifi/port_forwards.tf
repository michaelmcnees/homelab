locals {
  traefik_external_port_forwards = {
    http = {
      name         = "HTTP"
      wan_port     = "80"
      forward_port = "81"
    }
    https = {
      name         = "HTTPS"
      wan_port     = "443"
      forward_port = "444"
    }
  }
}

resource "unifi_port_forward" "traefik_external" {
  for_each = local.traefik_external_port_forwards

  name                   = each.value.name
  protocol               = "tcp"
  port_forward_interface = "wan"
  dst_port               = each.value.wan_port
  fwd_ip                 = "10.0.10.200"
  fwd_port               = each.value.forward_port
  log                    = true
}
