output "vm_name" {
  value = google_compute_instance.agents.name
}

output "vm_zone" {
  value = google_compute_instance.agents.zone
}

output "iap_ssh_command" {
  value = "gcloud compute ssh ${google_compute_instance.agents.name} --zone ${google_compute_instance.agents.zone} --project ${var.project_id} --tunnel-through-iap"
}
