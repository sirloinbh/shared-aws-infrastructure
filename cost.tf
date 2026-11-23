# Cost anomaly detection (#100). AWS watches the spend of each service and emails the budget recipients
# when it jumps above the usual pattern. Free. It complements the fixed monthly budget in main.tf, which
# fires late and only on the total: a leaked key that creates resources shows up first as one service jumping.
#
# An account allows only one dimensional SERVICE monitor. If AWS already made a default one, import it
# instead of creating this one (docs/operations.md, section "Cost anomaly alert").
resource "aws_ce_anomaly_monitor" "services" {
  name              = "${var.project}-services"
  monitor_type      = "DIMENSIONAL"
  monitor_dimension = "SERVICE"
  depends_on        = [terraform_data.account_guard]
}

resource "aws_ce_anomaly_subscription" "daily" {
  name             = "${var.project}-daily"
  frequency        = "DAILY"
  monitor_arn_list = [aws_ce_anomaly_monitor.services.arn]

  dynamic "subscriber" {
    for_each = toset(var.budget_emails)
    content {
      type    = "EMAIL"
      address = subscriber.value
    }
  }

  threshold_expression {
    dimension {
      key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
      match_options = ["GREATER_THAN_OR_EQUAL"]
      values        = [tostring(var.cost_anomaly_threshold_usd)]
    }
  }
}
