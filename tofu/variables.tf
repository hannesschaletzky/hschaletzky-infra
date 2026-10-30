variable "state_passphrase" {
  description = "Passphrase für die State-Verschlüsselung (mind. 16 Zeichen). Kommt aus TF_VAR_state_passphrase."
  type        = string
  sensitive   = true
}

variable "location" {
  description = "Hetzner-Standort"
  type        = string
  default     = "nbg1"
}

variable "server_type" {
  type    = string
  default = "cx23"
}

variable "admin_user" {
  description = "Login für Menschen (sudo, docker)"
  type        = string
  default     = "hannes"
}

variable "hschaletzky_auf_server" {
  description = "Erst auf true setzen, wenn der hschaletzky-Container läuft. Bis dahin zeigt die Domain weiter auf Vercel."
  type        = bool
  default     = false
}
