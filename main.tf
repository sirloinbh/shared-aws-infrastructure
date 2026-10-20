# Workout Memo first deployment (#73): one Lightsail instance running Docker Compose
# (web, API, PostgreSQL), reachable only from allowed IPs, with daily snapshots and a
# monthly cost alert. Runbook: docs/deployment.md.
locals {
  tags = { Project = var.project }
}

data "aws_caller_identity" "current" {}

# Stops a plan or apply made with the wrong (e.g. company) credentials.
resource "terraform_data" "account_guard" {
  input = data.aws_caller_identity.current.account_id
  lifecycle {
    precondition {
      condition     = data.aws_caller_identity.current.account_id == var.expected_account_id
      error_message = "현재 AWS 자격 증명의 계정이 expected_account_id와 다릅니다. aws_profile을 확인하세요."
    }
  }
}

resource "aws_lightsail_key_pair" "deploy" {
  name       = "${var.project}-deploy"
  public_key = file(pathexpand(var.ssh_public_key_path))
  depends_on = [terraform_data.account_guard]
}

resource "aws_lightsail_instance" "app" {
  name              = "${var.project}-app"
  availability_zone = "${var.region}a"
  blueprint_id      = "ubuntu_24_04"
  bundle_id         = var.bundle_id
  key_pair_name     = aws_lightsail_key_pair.deploy.name
  ip_address_type   = "ipv4"
  user_data = templatefile("${path.module}/user-data.sh", {
    repo_url    = var.repo_url
    backup_days = var.backup_retention_days
  })
  add_on {
    type          = "AutoSnapshot"
    snapshot_time = var.snapshot_time_utc
    status        = "Enabled"
  }
  tags = local.tags
  lifecycle {
    # user_data only runs at first boot; changing it would replace the instance and its data.
    ignore_changes = [user_data]
  }
}

resource "aws_lightsail_static_ip" "app" {
  name       = "${var.project}-ip"
  depends_on = [terraform_data.account_guard]
}

resource "aws_lightsail_static_ip_attachment" "app" {
  static_ip_name = aws_lightsail_static_ip.app.name
  instance_name  = aws_lightsail_instance.app.name
}

# Replaces the default firewall: only SSH and HTTP, only from the allow list.
resource "aws_lightsail_instance_public_ports" "app" {
  instance_name = aws_lightsail_instance.app.name
  port_info {
    protocol  = "tcp"
    from_port = 22
    to_port   = 22
    cidrs     = var.allowed_cidrs
  }
  port_info {
    protocol  = "tcp"
    from_port = 80
    to_port   = 80
    cidrs     = var.allowed_cidrs
  }
}

# An alert, not a spending cap. Covers the whole (personal) account.
resource "aws_budgets_budget" "monthly" {
  name         = "${var.project}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"
  dynamic "notification" {
    for_each = [
      { threshold = 50, type = "ACTUAL" },
      { threshold = 80, type = "ACTUAL" },
      { threshold = 100, type = "FORECASTED" },
    ]
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value.threshold
      threshold_type             = "PERCENTAGE"
      notification_type          = notification.value.type
      subscriber_email_addresses = var.budget_emails
    }
  }
  depends_on = [terraform_data.account_guard]
}
