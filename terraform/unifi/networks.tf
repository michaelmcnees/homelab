locals {
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
  dhcp_dns     = ["10.0.10.201"]

  multicast_dns = true

  lifecycle {
    ignore_changes = [
      subnet,
    ]
  }
}
