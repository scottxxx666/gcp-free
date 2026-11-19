variable "project_id" {
  description = "GCP project ID to deploy into."
  type        = string
}

variable "billing_account_id" {
  description = "Billing account ID linked to the project (format: XXXXXX-XXXXXX-XXXXXX)."
  type        = string

  validation {
    condition     = can(regex("^[0-9A-F]{6}-[0-9A-F]{6}-[0-9A-F]{6}$", var.billing_account_id))
    error_message = "billing_account_id must look like 012345-6789AB-CDEF01."
  }
}

variable "region" {
  description = "Region for the VM. Only these three regions qualify for the Always Free e2-micro."
  type        = string
  default     = "us-central1"

  validation {
    condition     = contains(["us-west1", "us-central1", "us-east1"], var.region)
    error_message = "region must be us-west1, us-central1 or us-east1 (Always Free e2-micro regions)."
  }
}

variable "zone" {
  description = "Zone for the VM; must be inside var.region."
  type        = string
  default     = "us-central1-a"

  validation {
    condition     = startswith(var.zone, "${var.region}-")
    error_message = "zone must belong to var.region (e.g. us-central1-a)."
  }
}

variable "name_prefix" {
  description = "Prefix for resource names."
  type        = string
  default     = "agents"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,19}$", var.name_prefix))
    error_message = "name_prefix must be lowercase letters, digits or hyphens, start with a letter, 3-20 chars (the SA id \"<prefix>-vm\" needs 6-30)."
  }
}

variable "subnet_cidr" {
  description = "Primary IPv4 range of the subnet."
  type        = string
  default     = "10.10.0.0/24"
}

variable "boot_disk_size_gb" {
  description = "Boot disk size in GB (pd-standard). Always Free covers 30 GB-months in total across the project."
  type        = number
  default     = 30

  validation {
    condition     = var.boot_disk_size_gb >= 10 && var.boot_disk_size_gb <= 30
    error_message = "boot_disk_size_gb must be between 10 and 30 to stay within the free 30 GB-months."
  }
}

# Network tier of the ephemeral external IP. This affects egress pricing only.
#   PREMIUM  - Traffic rides Google's backbone to the edge closest to the destination.
#              The Always Free tier lists "1 GB of outbound data transfer from North
#              America to all region destinations (excluding China and Australia)
#              per month" (verified on the Free Tier page, 2026-10). Egress beyond 1 GB
#              is billed at Premium rates.
#   STANDARD - Traffic leaves Google's network near the VM's region and uses the public
#              internet. Per-GB rates are lower than Premium. Whether Standard has its own
#              free monthly allowance, and whether the 1 GB free tier also applies to it,
#              is Unverified: check https://cloud.google.com/network-tiers/pricing before
#              switching.
# The external IPv4 address itself costs the same on either tier (see README).
variable "network_tier" {
  description = "Network tier for the ephemeral external IP: PREMIUM or STANDARD."
  type        = string
  default     = "PREMIUM"

  validation {
    condition     = contains(["PREMIUM", "STANDARD"], var.network_tier)
    error_message = "network_tier must be PREMIUM or STANDARD."
  }
}

variable "enable_ops_roles" {
  description = "Grant the VM SA roles/logging.logWriter and roles/monitoring.metricWriter (plus matching scopes), and ship container logs to Cloud Logging via Docker's gcplogs driver. false = SA has no roles or scopes, and logs stay on the VM (rotating local driver)."
  type        = bool
  default     = true
}

variable "budget_amount" {
  description = "Monthly budget in whole units of budget_currency_code. The default of 5 covers the ~3.6 USD/month external IPv4 charge, so the 50% alert still means something."
  type        = number
  default     = 5

  validation {
    condition     = var.budget_amount >= 1 && floor(var.budget_amount) == var.budget_amount
    error_message = "budget_amount must be a whole number >= 1."
  }
}

variable "budget_currency_code" {
  description = "Currency of the budget. Must match the billing account's currency or the API rejects it."
  type        = string
  default     = "USD"
}
