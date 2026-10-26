variable "project_id" {
  description = "The GCP Project ID"
  type        = string
}

variable "region" {
  description = "The GCP Region"
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "The GCP Zone"
  type        = string
  default     = "us-central1-a"
}

variable "tailscale_auth_key" {
  description = "Reusable Tailscale auth key used only to enroll this VM. Keep it in a gitignored tfvars file."
  type        = string
  sensitive   = true
}

variable "tailscale_hostname" {
  description = "The name shown for this VM in Tailscale and used by MagicDNS."
  type        = string
  default     = "comfyui"
}

