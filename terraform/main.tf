resource "google_compute_instance" "comfy-ui-server" {
  name = "comfy-ui-server"
  zone = var.zone

  # N1 high-memory machine: 8 vCPUs, 52 GB RAM. The additional system memory
  # provides headroom for ComfyUI model offloading alongside the 16 GB T4.
  machine_type = "n1-highmem-8"

  # Script to run immidiately after startup
  metadata_startup_script = file("${path.module}/../scripts/startup.sh")

  # Supplied from a local, gitignored tfvars file. The startup script uses it
  # once to enroll a newly created VM in the private Tailscale network.
  metadata = {
    tailscale-auth-key = var.tailscale_auth_key
    tailscale-hostname = var.tailscale_hostname
  }

  tags = ["comfy-ui"]

  guest_accelerator {
    type  = "nvidia-tesla-t4"
    count = 1
  }

  # --- SPOT VM CONFIGURATION ---
  scheduling {
    on_host_maintenance = "TERMINATE"

    # Spot VMs cannot automatically restart when reclaimed by Google
    automatic_restart = false

    # Enables Spot pricing (formerly "Preemptible")
    provisioning_model = "SPOT"
    preemptible        = true
  }
  # -----------------------------

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
      size  = 100
      type  = "pd-balanced"
    }
  }

  network_interface {
    network = "default"
    access_config {
      # Ephemeral Public IP
    }
  }

  allow_stopping_for_update = true
}
