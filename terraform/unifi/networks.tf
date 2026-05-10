locals {
  adguard_dns_vip = "10.0.10.201"

  vlan_networks = {
    k8s = {
      name       = "K8s"
      purpose    = "corporate"
      vlan_id    = 10
      subnet     = "10.0.10.1/24"
      dhcp_start = "10.0.10.100"
      dhcp_stop  = "10.0.10.199"
    }
    trusted = {
      name       = "Trusted"
      purpose    = "corporate"
      vlan_id    = 20
      subnet     = "10.0.20.1/24"
      dhcp_start = "10.0.20.100"
      dhcp_stop  = "10.0.20.254"
    }
    iot = {
      name       = "IoT"
      purpose    = "corporate"
      vlan_id    = 30
      subnet     = "10.0.30.1/24"
      dhcp_start = "10.0.30.100"
      dhcp_stop  = "10.0.30.254"
    }
    storage = {
      name       = "Storage"
      purpose    = "corporate"
      vlan_id    = 40
      subnet     = "10.0.40.1/24"
      dhcp_start = "10.0.40.100"
      dhcp_stop  = "10.0.40.254"
    }
    guest = {
      name       = "Guest"
      purpose    = "corporate"
      vlan_id    = 50
      subnet     = "10.0.50.1/24"
      dhcp_start = "10.0.50.100"
      dhcp_stop  = "10.0.50.254"
    }
  }
}

resource "unifi_network" "vlans" {
  for_each = local.vlan_networks

  name    = each.value.name
  purpose = each.value.purpose
  subnet  = each.value.subnet
  vlan_id = each.value.vlan_id

  dhcp_enabled = true
  dhcp_start   = each.value.dhcp_start
  dhcp_stop    = each.value.dhcp_stop
  dhcp_lease   = 86400
  dhcp_dns     = [local.adguard_dns_vip]

  multicast_dns = true

  lifecycle {
    ignore_changes = [
      subnet,
    ]
  }
}

resource "unifi_network" "mclan" {
  name    = "McLan"
  purpose = "corporate"
  subnet  = "10.0.0.1/22"

  dhcp_enabled = true
  dhcp_dns     = [local.adguard_dns_vip]

  lifecycle {
    ignore_changes = [
      dhcp_enabled,
      dhcp_lease,
      dhcp_start,
      dhcp_stop,
      dhcp_v6_start,
      dhcp_v6_stop,
      ipv6_pd_start,
      ipv6_pd_stop,
      ipv6_ra_enable,
      ipv6_ra_priority,
      ipv6_ra_valid_lifetime,
      multicast_dns,
      subnet,
      vlan_id,
    ]
  }
}
