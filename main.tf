locals {
  vm_name     = "${var.name_prefix}-vm"
  iap_ssh_tag = "${var.name_prefix}-iap-ssh"

  # Hard-coded so they can't drift out of the Always Free tier through a tfvars change.
  machine_type   = "e2-micro"
  boot_disk_type = "pd-standard"

  apis = toset([
    "compute.googleapis.com",
    "iam.googleapis.com",
    "iap.googleapis.com",
    "oslogin.googleapis.com",
    "billingbudgets.googleapis.com",
    "logging.googleapis.com",
  ])
}

resource "google_project_service" "apis" {
  for_each = local.apis

  service = each.value

  # Leave APIs on when this stack is destroyed; other resources in the project may use them.
  disable_on_destroy = false
}

data "google_compute_image" "debian" {
  family  = "debian-12"
  project = "debian-cloud"

  # Read needs compute.googleapis.com on in this project; on a fresh project it isn't yet.
  depends_on = [google_project_service.apis]
}

resource "google_compute_instance" "agents" {
  name         = local.vm_name
  zone         = var.zone
  machine_type = local.machine_type
  tags         = [local.iap_ssh_tag]

  boot_disk {
    initialize_params {
      image = data.google_compute_image.debian.self_link
      size  = var.boot_disk_size_gb
      type  = local.boot_disk_type
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.this.id

    # Ephemeral external IP (no nat_ip = not reserved), used for outbound
    # traffic only because there is no Cloud NAT. The firewall allows no
    # inbound traffic from the internet.
    access_config {
      network_tier = var.network_tier
    }
  }

  service_account {
    email  = google_service_account.vm.email
    scopes = local.vm_scopes
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  metadata = {
    enable-oslogin         = "TRUE"
    block-project-ssh-keys = "TRUE"
    # Set as plain metadata, not metadata_startup_script, so editing the script
    # updates in place instead of recreating the VM. GCE reruns it on every boot.
    startup-script = file("${path.module}/scripts/startup.sh")
    # Read by startup.sh. gcplogs without the logWriter role fails container start.
    docker-log-driver = var.enable_ops_roles ? "gcplogs" : "local"
  }

  depends_on = [google_project_iam_member.vm_ops]
}
