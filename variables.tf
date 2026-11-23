variable "aws_profile" {
  type        = string
  description = "AWS CLI profile of the personal account that owns this deployment."
}
variable "expected_account_id" {
  type        = string
  description = "Account ID the profile must resolve to; plan fails on any other account."
  validation {
    condition     = can(regex("^[0-9]{12}$", var.expected_account_id))
    error_message = "Enter the 12-digit AWS account ID."
  }
}
variable "region" {
  type    = string
  default = "ap-northeast-2"
}
# Historical name: the shared server started as workout-memo's. Do not rename it; the name is part of
# the Lightsail instance, static IP, key pair, and budget names, so a new value replaces them.
variable "project" {
  type    = string
  default = "workout-memo"
}
variable "bundle_id" {
  type        = string
  default     = "micro_3_0"
  description = "Lightsail plan. micro_3_0 = 1 GB RAM, 40 GB SSD, IPv4, 2 TB transfer, USD 7/month. small_3_0 = 2 GB, 60 GB, USD 12/month. Changing it here replaces the instance with a blank one; resize from a snapshot instead (docs/operations.md section 11)."
}
variable "instance_name" {
  type        = string
  default     = null
  description = "Lightsail instance name. Defaults to <project>-app. A resize from a snapshot needs a new name (docs/operations.md section 11)."
}
variable "allowed_cidrs" {
  type        = list(string)
  description = "IPv4 CIDRs allowed to reach SSH (22) and the web (80, 443). Add new networks here."
  validation {
    condition = length(var.allowed_cidrs) > 0 && alltrue([
      for c in var.allowed_cidrs : can(cidrhost(c, 0)) && !endswith(c, "/0")
    ])
    error_message = "allowed_cidrs must have at least one IPv4 CIDR, and opening to everyone (/0) is not allowed."
  }
}
variable "ssh_public_key_path" {
  type    = string
  default = "~/.ssh/workout-memo-lightsail.pub"
}
variable "root_domain" {
  type        = string
  default     = "daysofme.com"
  description = "Shared domain registered in Route 53 (project-standards registry rootDomain). Each app is <name>.<root_domain>."
}
variable "budget_emails" {
  type        = list(string)
  description = "Recipients of the monthly cost alerts. Keep them in terraform.tfvars (git-ignored)."
}
variable "monthly_budget_usd" {
  type        = number
  default     = 20
  description = "Monthly alert amount for the whole account, in USD. Keep it above the real monthly cost (about USD 15-17 with VAT for the 2 GB plan, docs/operations.md), or the alerts fire every month."
}
# Recommended value (#73): daily snapshot at 03:00 Seoul (AWS keeps the latest 7).
# The snapshot is the recovery path for the whole server (#64).
variable "snapshot_time_utc" {
  type    = string
  default = "18:00"
}
# Off-site dump copies in S3 (#7): current and overwritten versions expire after this many days.
variable "offsite_backup_days" {
  type    = number
  default = 30
}

# How long a deleted or overwritten app file stays recoverable as an earlier version (#53).
variable "app_file_recovery_days" {
  type    = number
  default = 30
}

# How long an earlier Terraform state version stays in the state bucket (#63).
variable "state_version_days" {
  type    = number
  default = 90
}

# Study notes wiki (wiki.tf). SHA-256 (64 lower-case hex characters) of the Authorization header
# the browser sends for the wiki's user name and password. docs/operations.md section 12 shows
# how to compute it; the password itself is stored nowhere.
variable "wiki_auth_sha256" {
  type        = string
  description = "SHA-256 of the HTTP basic authentication header of the wiki. Keep it in terraform.tfvars (git-ignored)."
  validation {
    condition     = can(regex("^[0-9a-f]{64}$", var.wiki_auth_sha256))
    error_message = "Enter 64 lower-case hex characters (docs/operations.md section 12)."
  }
}
# The repository uses GitHub's immutable OIDC subject, which names the owner and repository by
# their IDs as well as their names. A repository renamed later, or deleted and re-created with the
# same name, gets a new ID and so cannot assume the deploy role (docs/operations.md section 12-3).
# The IDs are public, not secrets.
variable "wiki_oidc_subject_prefix" {
  type        = string
  default     = "repo:sirloinbh@129952654/develop-skill@1442840255"
  description = "OIDC sub prefix of the repository whose main-branch workflow may deploy the wiki: repo:<owner>@<owner ID>/<repo>@<repo ID>."

  validation {
    condition     = can(regex("^repo:[^@/:]+@[0-9]+/[^@/:]+@[0-9]+$", var.wiki_oidc_subject_prefix))
    error_message = "Use the immutable form repo:<owner>@<owner ID>/<repo>@<repo ID> (gh api repos/<owner>/<repo>/actions/oidc/customization/sub)."
  }
}
variable "uptime_alert_emails" {
  type        = list(string)
  default     = []
  description = "Recipients of the uptime alerts (#105). Empty means the same recipients as budget_emails. Keep them in terraform.tfvars (git-ignored)."
}
variable "cost_anomaly_threshold_usd" {
  type        = number
  default     = 5
  description = "Cost anomaly alert (#100): email when one service's unexpected spend (total impact) is at least this many USD."
}
