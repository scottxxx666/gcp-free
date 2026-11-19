resource "google_compute_network" "this" {
  name                    = "${var.name_prefix}-vpc"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"

  depends_on = [google_project_service.apis]
}

resource "google_compute_subnetwork" "this" {
  name          = "${var.name_prefix}-subnet"
  region        = var.region
  network       = google_compute_network.this.id
  ip_cidr_range = var.subnet_cidr

  # No flow logs: they are ingested into Cloud Logging and can bill.
  private_ip_google_access = true
}

# The only ingress rule. A custom VPC already has an implied "deny all ingress"
# rule at the lowest priority, so everything else stays blocked without an
# explicit deny. Egress uses the implied "allow all egress" rule.
resource "google_compute_firewall" "allow_iap_ssh" {
  name      = "${var.name_prefix}-allow-iap-ssh"
  network   = google_compute_network.this.id
  direction = "INGRESS"
  priority  = 1000

  # Google's published IAP TCP forwarding range.
  source_ranges = ["35.235.240.0/20"]
  target_tags   = [local.iap_ssh_tag]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}
