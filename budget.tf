data "google_project" "this" {
  project_id = var.project_id
}

# A budget only sends alerts. It does not cap or stop spending.
# With no notification channels set, alerts email the billing account's
# Billing Admins and Billing Account Users.
resource "google_billing_budget" "this" {
  billing_account = var.billing_account_id
  display_name    = "${var.name_prefix}-monthly"

  budget_filter {
    projects = ["projects/${data.google_project.this.number}"]

    # Subtract only Always Free credits. Free Trial credits (PROMOTION) are not
    # subtracted, so usage beyond the free tier still triggers alerts during the trial.
    credit_types_treatment = "INCLUDE_SPECIFIED_CREDITS"
    credit_types           = ["FREE_TIER"]
  }

  amount {
    specified_amount {
      currency_code = var.budget_currency_code
      units         = tostring(var.budget_amount)
    }
  }

  threshold_rules {
    threshold_percent = 0.5
  }

  threshold_rules {
    threshold_percent = 1.0
  }

  depends_on = [google_project_service.apis]
}
