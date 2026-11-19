resource "google_service_account" "vm" {
  account_id   = local.vm_name
  display_name = "Dedicated SA for ${var.name_prefix} VM (no default compute SA)"

  depends_on = [google_project_service.apis]
}

locals {
  ops_roles = var.enable_ops_roles ? toset([
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
  ]) : toset([])

  # Scopes cap what the SA token can do. With no roles there is nothing to grant,
  # so the token gets no scopes at all.
  vm_scopes = var.enable_ops_roles ? [
    "https://www.googleapis.com/auth/logging.write",
    "https://www.googleapis.com/auth/monitoring.write",
  ] : []
}

resource "google_project_iam_member" "vm_ops" {
  for_each = local.ops_roles

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.vm.email}"
}
