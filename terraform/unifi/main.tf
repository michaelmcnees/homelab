provider "unifi" {
  api_url        = var.unifi_api_url
  api_key        = var.unifi_api_key != "" ? var.unifi_api_key : null
  username       = var.unifi_api_key == "" && var.unifi_username != "" ? var.unifi_username : null
  password       = var.unifi_api_key == "" && var.unifi_password != "" ? var.unifi_password : null
  site           = var.unifi_site
  allow_insecure = var.unifi_allow_insecure
}
