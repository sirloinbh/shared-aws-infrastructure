# Workout Memo first deployment (#73): one Lightsail instance running Docker Compose
# (web, API, PostgreSQL), reachable only from allowed IPs, with daily snapshots and a
# monthly cost alert. Runbook: docs/deployment.md.
locals {
  tags = { Project = var.project }
  # Server identities every app on the server shares (#7, #8) are not named after one app
  # (project-standards ADR-0010, #266).
  shared_prefix = "sirloinbh-apps"
}

data "aws_caller_identity" "current" {}

# Stops a plan or apply made with the wrong (e.g. company) credentials.
resource "terraform_data" "account_guard" {
  input = data.aws_caller_identity.current.account_id
  lifecycle {
    precondition {
      condition     = data.aws_caller_identity.current.account_id == var.expected_account_id
      error_message = "The current AWS credentials belong to an account other than expected_account_id. Check aws_profile."
    }
  }
}

resource "aws_lightsail_key_pair" "deploy" {
  name       = "${var.project}-deploy"
  public_key = file(pathexpand(var.ssh_public_key_path))
  depends_on = [terraform_data.account_guard]
}

resource "aws_lightsail_instance" "app" {
  name              = coalesce(var.instance_name, "${var.project}-app")
  availability_zone = "${var.region}a"
  blueprint_id      = "ubuntu_24_04"
  bundle_id         = var.bundle_id
  key_pair_name     = aws_lightsail_key_pair.deploy.name
  ip_address_type   = "ipv4"
  # Host baseline only; the snapshot is the recovery path for the whole server (#64).
  user_data = file("${path.module}/user-data.sh")
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

# Replaces the default firewall: only SSH, HTTP, and HTTPS, only from the allow list.
# 443 is the app subdomains through the server nginx (#33). The certificate uses DNS validation,
# so 80 never has to be open to everyone.
# Browser SSH in the Lightsail console adds cidr_list_aliases to 22, and the next plan replaces
# this resource; remove them as in docs/operations.md section 6 (#43).
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
  port_info {
    protocol  = "tcp"
    from_port = 443
    to_port   = 443
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
