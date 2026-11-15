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
variable "repo_url" {
  type    = string
  default = "https://github.com/sirloinbh/workout-memo.git"
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
  type    = number
  default = 10
}
# Recommended values (#73): daily snapshot at 03:00 Seoul (AWS keeps the latest 7)
# and a nightly database dump kept 14 days on the server.
variable "snapshot_time_utc" {
  type    = string
  default = "18:00"
}
variable "backup_retention_days" {
  type    = number
  default = 14
}
# Off-site dump copies in S3 (#7): current and overwritten versions expire after this many days.
variable "offsite_backup_days" {
  type    = number
  default = 30
}
