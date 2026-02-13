variable "project_id" {
  description = "The GCP Project ID"
  type        = string
}

variable "region" {
  description = "The GCP Region"
  type        = string
  default     = "africa-south1"
}

variable "zone" {
  description = "The GCP Zone"
  type        = string
  default     = "africa-south1-a"
}

