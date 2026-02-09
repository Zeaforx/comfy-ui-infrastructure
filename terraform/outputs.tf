output "comfy_ui_url" {
  description = "The URL to access ComfyUI"
  value       = "http://${google_compute_instance.comfy-ui-server.network_interface.0.access_config.0.nat_ip}:8188"
}
