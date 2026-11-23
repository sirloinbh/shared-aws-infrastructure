# The uptime alert path (#105, project-standards#1058 and #1091): the server sends two custom metrics
# and publishes failing signal names to one SNS topic; two alarms and the topic email the user.
# The server's `signals.sh evaluate` (project-standards, every 5 minutes) sends HeartbeatOk (always 1)
# and FailingSignals (how many signals fail or are stale). Metrics are regional, so everything here is
# in var.region. Runbook: docs/operations.md section 8.
locals {
  uptime_namespace = "ProjectStandards/Uptime" # must equal AWS_ALERT_NAMESPACE on the server and the script's UPTIME_NAMESPACE
  uptime_topic     = "sirloinbh-uptime-alerts" # the boundary, terraform-uptime-alerts and the script's UPTIME_TOPIC name this topic
  uptime_emails    = length(var.uptime_alert_emails) > 0 ? var.uptime_alert_emails : var.budget_emails
}

# The topic and the alarms wait for terraform-uptime-alerts to be attached to the Terraform user.
resource "aws_sns_topic" "uptime" {
  name       = local.uptime_topic
  tags       = local.tags
  depends_on = [terraform_data.account_guard, aws_iam_user_policy_attachment.terraform["terraform-uptime-alerts"]]
}

# The recipient confirms each subscription by the AWS email; until then it stays pending.
resource "aws_sns_topic_subscription" "uptime_email" {
  for_each  = toset(local.uptime_emails)
  topic_arn = aws_sns_topic.uptime.arn
  protocol  = "email"
  endpoint  = each.value
}

# The server's alert identity: it can put metrics in one namespace and publish to this one topic, nothing
# else. It is not the upload-only backup key. Its access key is made in the console (docs/operations.md
# section 10) so the secret never enters the Terraform state; rotation follows #104.
resource "aws_iam_user" "uptime_alerts" {
  name                 = "${local.shared_prefix}-uptime-alerts"
  permissions_boundary = local.terraform_server_user_boundary
  tags                 = local.tags
  depends_on           = [terraform_data.account_guard]
}

resource "aws_iam_user_policy" "uptime_alerts" {
  name = "send-uptime-signals"
  user = aws_iam_user.uptime_alerts.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "PutUptimeMetrics"
        Effect   = "Allow"
        Action   = "cloudwatch:PutMetricData"
        Resource = "*"
        Condition = {
          StringEquals = { "cloudwatch:namespace" = local.uptime_namespace }
        }
      },
      {
        Sid      = "PublishUptimeSignals"
        Effect   = "Allow"
        Action   = "sns:Publish"
        Resource = aws_sns_topic.uptime.arn
      },
    ]
  })
}

# Dead-man switch: the server sends HeartbeatOk = 1 every 5 minutes. Missing data counts as breaching, so a
# dead server, a stopped timer, a broken network or a revoked key raises the alarm after 3 empty periods.
resource "aws_cloudwatch_metric_alarm" "uptime_heartbeat" {
  alarm_name          = "sirloinbh-uptime-heartbeat"
  alarm_description   = "The server stopped sending HeartbeatOk for 15 minutes (dead server, stopped public-check timer, network or key problem)."
  namespace           = local.uptime_namespace
  metric_name         = "HeartbeatOk"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_sns_topic.uptime.arn]
  ok_actions          = [aws_sns_topic.uptime.arn]
  tags                = local.tags
  depends_on          = [terraform_data.account_guard, aws_iam_user_policy_attachment.terraform["terraform-uptime-alerts"]]
}

# At least one signal on the server fails or is stale. Missing data keeps the current state: a dead server is
# the heartbeat alarm's job, and this alarm must not send a false OK mail then.
resource "aws_cloudwatch_metric_alarm" "uptime_failing_signals" {
  alarm_name          = "sirloinbh-uptime-failing-signals"
  alarm_description   = "One or more server signals are failing or stale. The SNS message from the server names them."
  namespace           = local.uptime_namespace
  metric_name         = "FailingSignals"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  treat_missing_data  = "ignore"
  alarm_actions       = [aws_sns_topic.uptime.arn]
  ok_actions          = [aws_sns_topic.uptime.arn]
  tags                = local.tags
  depends_on          = [terraform_data.account_guard, aws_iam_user_policy_attachment.terraform["terraform-uptime-alerts"]]
}
