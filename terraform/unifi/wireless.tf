locals {
  wireless_networks = {
    mcnet = {
      name                 = "McNet"
      network_id           = unifi_network.vlans["trusted"].id
      user_group_id        = "6499a7124f7a9a2eefafa824"
      security             = "wpapsk"
      wlan_band            = "both"
      ap_group_ids         = ["6499a7124f7a9a2eefafa829"]
      bss_transition       = true
      fast_roaming_enabled = false
      hide_ssid            = false
      is_guest             = false
      l2_isolation         = false
      multicast_enhance    = false
      no2ghz_oui           = true
      pmf_mode             = "optional"
      proxy_arp            = false
      uapsd                = false
      wpa3_support         = true
      wpa3_transition      = true
      mac_filter_enabled   = false
    }
    mcnet_iot = {
      name                 = "McNet_IoT"
      network_id           = unifi_network.vlans["iot"].id
      user_group_id        = "6499a7124f7a9a2eefafa824"
      security             = "wpapsk"
      wlan_band            = "2g"
      ap_group_ids         = ["6499a7124f7a9a2eefafa829"]
      bss_transition       = false
      fast_roaming_enabled = false
      hide_ssid            = true
      is_guest             = false
      l2_isolation         = false
      multicast_enhance    = true
      no2ghz_oui           = false
      pmf_mode             = "disabled"
      proxy_arp            = false
      uapsd                = false
      wpa3_support         = false
      wpa3_transition      = false
      mac_filter_enabled   = false
    }
    mcnet_guest = {
      name                 = "McNet Guest"
      network_id           = unifi_network.vlans["guest"].id
      user_group_id        = "67e7612450d7042c77aa929a"
      security             = "wpapsk"
      wlan_band            = "both"
      ap_group_ids         = ["67e7617c50d7042c77aa92ca"]
      bss_transition       = true
      fast_roaming_enabled = false
      hide_ssid            = false
      is_guest             = true
      l2_isolation         = true
      multicast_enhance    = false
      no2ghz_oui           = true
      pmf_mode             = "disabled"
      proxy_arp            = false
      uapsd                = false
      wpa3_support         = false
      wpa3_transition      = false
      mac_filter_enabled   = false
    }
  }
}

resource "unifi_wlan" "wireless_networks" {
  for_each = local.wireless_networks

  name                 = each.value.name
  network_id           = each.value.network_id
  user_group_id        = each.value.user_group_id
  security             = each.value.security
  wlan_band            = each.value.wlan_band
  ap_group_ids         = each.value.ap_group_ids
  bss_transition       = each.value.bss_transition
  fast_roaming_enabled = each.value.fast_roaming_enabled
  hide_ssid            = each.value.hide_ssid
  is_guest             = each.value.is_guest
  l2_isolation         = each.value.l2_isolation
  mac_filter_enabled   = each.value.mac_filter_enabled
  multicast_enhance    = each.value.multicast_enhance
  no2ghz_oui           = each.value.no2ghz_oui
  pmf_mode             = each.value.pmf_mode
  proxy_arp            = each.value.proxy_arp
  uapsd                = each.value.uapsd
  wpa3_support         = each.value.wpa3_support
  wpa3_transition      = each.value.wpa3_transition

  lifecycle {
    ignore_changes = [
      mac_filter_list,
      mac_filter_policy,
      minimum_data_rate_2g_kbps,
      minimum_data_rate_5g_kbps,
      passphrase,
    ]
  }
}
