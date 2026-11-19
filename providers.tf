provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone

  # The Billing Budgets API rejects user ADC credentials unless the request names
  # a quota project. These two settings bill API quota to this project.
  billing_project       = var.project_id
  user_project_override = true
}
