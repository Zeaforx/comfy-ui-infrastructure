resource "google_compute_instance" "comfy-ui-server" {
  name = "comfy-ui-server"
  zone = var.zone

  # Custom N1 machine: 6 vCPUs, 16 GB RAM
  machine_type = "custom-6-16384"

  # Script to run immidiately after startup
  metadata_startup_script = file("${path.module}/../scripts/startup.sh")

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

resource "google_compute_firewall" "allow_comfy_ui_web" {
  name    = "allow-comfy-ui-web"
  network = "default"

  allow {
    protocol = "tcp"
    ports    = ["80", "443", "8188"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["comfy-ui"]
}
