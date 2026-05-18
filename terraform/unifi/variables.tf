variable "unifi_api_url" {
  description = "UniFi controller URL without /api path, e.g. https://10.0.0.1 or https://unifi.local"
  type        = string
}

variable "unifi_api_key" {
  description = "UniFi API key. Requires UniFi Network 9.0.108 or newer. Leave empty to use username/password auth."
  type        = string
  sensitive   = true
  default     = ""
}

variable "unifi_username" {
  description = "Local UniFi admin username. Used only when unifi_api_key is empty."
  type        = string
  default     = ""
}

variable "unifi_password" {
  description = "Local UniFi admin password. Used only when unifi_api_key is empty."
  type        = string
  sensitive   = true
  default     = ""
}

variable "unifi_site" {
  description = "UniFi site short name used in API paths, not the display name. Usually default."
  type        = string
  default     = "default"
}

variable "unifi_allow_insecure" {
  description = "Allow self-signed UniFi controller TLS certificates"
  type        = bool
  default     = true
}
