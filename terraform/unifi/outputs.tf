output "vlan_network_ids" {
  description = "UniFi network IDs keyed by logical VLAN name"
  value = {
    for name, network in unifi_network.vlans : name => network.id
  }
}
