locals {
  port_forwards = {
    http = {
      name                   = "HTTP"
      protocol               = "tcp"
      port_forward_interface = "wan"
      dst_port               = "80"
      fwd_ip                 = "10.0.10.200"
      fwd_port               = "81"
      log                    = true
    }
    https = {
      name                   = "HTTPS"
      protocol               = "tcp"
      port_forward_interface = "wan"
      dst_port               = "443"
      fwd_ip                 = "10.0.10.200"
      fwd_port               = "444"
      log                    = true
    }
    plex = {
      name                   = "Plex"
      protocol               = "tcp"
      port_forward_interface = "wan"
      dst_port               = "32400"
      fwd_ip                 = "10.0.1.1"
      fwd_port               = "32400"
      log                    = false
    }
    pterodactyl_allocations = {
      name                   = "Pterodactyl Allocations"
      protocol               = "tcp_udp"
      port_forward_interface = "wan"
      dst_port               = "25565-25569"
      fwd_ip                 = "10.0.2.20"
      fwd_port               = "25565-25569"
      log                    = false
    }
    satisfactory = {
      name                   = "Satisfactory"
      protocol               = "tcp_udp"
      port_forward_interface = "wan"
      dst_port               = "7777"
      fwd_ip                 = "10.0.2.37"
      fwd_port               = "7777"
      log                    = false
    }
    git = {
      name                   = "Git"
      protocol               = "tcp"
      port_forward_interface = "wan"
      dst_port               = "22"
      fwd_ip                 = "10.0.1.1"
      fwd_port               = "30009"
      log                    = false
    }
    pterodactyl_sftp = {
      name                   = "Pterodactyl SFTP"
      protocol               = "tcp_udp"
      port_forward_interface = "wan"
      dst_port               = "2022"
      fwd_ip                 = "10.0.2.20"
      fwd_port               = "2022"
      log                    = false
    }
    xbox_live = {
      name                   = "Xbox Live"
      protocol               = "tcp_udp"
      port_forward_interface = "both"
      dst_port               = "3074"
      fwd_ip                 = "10.0.0.80"
      fwd_port               = "3074"
      log                    = false
    }
    ldap = {
      name                   = "LDAP"
      protocol               = "tcp_udp"
      port_forward_interface = "wan"
      dst_port               = "3389,6636"
      fwd_ip                 = "10.0.1.100"
      fwd_port               = "3389,6636"
      log                    = false
    }
    https_cf = {
      name                   = "HTTPS (cf)"
      protocol               = "tcp"
      port_forward_interface = "wan"
      dst_port               = "8443"
      fwd_ip                 = "10.0.0.21"
      fwd_port               = "444"
      log                    = false
    }
    pelican_wings = {
      name                   = "Pelican Wings"
      protocol               = "tcp_udp"
      port_forward_interface = "wan"
      dst_port               = "27010-27020"
      fwd_ip                 = "10.0.0.64"
      fwd_port               = "27010-27020"
      log                    = false
    }
  }
}

moved {
  from = unifi_port_forward.traefik_external["http"]
  to   = unifi_port_forward.port_forwards["http"]
}

moved {
  from = unifi_port_forward.traefik_external["https"]
  to   = unifi_port_forward.port_forwards["https"]
}

resource "unifi_port_forward" "port_forwards" {
  for_each = local.port_forwards

  name                   = each.value.name
  protocol               = each.value.protocol
  port_forward_interface = each.value.port_forward_interface
  dst_port               = each.value.dst_port
  fwd_ip                 = each.value.fwd_ip
  fwd_port               = each.value.fwd_port
  src_ip                 = "any"
  log                    = each.value.log
}
