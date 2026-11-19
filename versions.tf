terraform {
  required_version = ">= 1.9" # cross-variable validation (var.zone vs var.region)

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.7"
    }
  }

  # State stays on local disk by default. terraform.tfstate holds the SA email and
  # project number, so it is gitignored.
  backend "local" {}

  # To move state to GCS, replace the block above with the one below and run
  # `terraform init -migrate-state`. Create the bucket in a US region
  # (us-west1 / us-central1 / us-east1) with the STANDARD storage class: the Cloud
  # Storage Always Free tier (5 GB-months) applies only to those regions.
  #
  #   gcloud storage buckets create gs://<PROJECT_ID>-tfstate \
  #     --location=us-central1 --default-storage-class=STANDARD \
  #     --uniform-bucket-level-access --public-access-prevention
  #   gcloud storage buckets update gs://<PROJECT_ID>-tfstate --versioning
  #
  # backend "gcs" {
  #   bucket = "<PROJECT_ID>-tfstate"
  #   prefix = "gcp-free-agents"
  # }
}
