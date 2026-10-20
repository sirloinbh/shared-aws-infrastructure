variable "aws_profile" {
  type        = string
  description = "AWS CLI profile of the personal account that owns this deployment."
}
variable "expected_account_id" {
  type        = string
  description = "Account ID the profile must resolve to; plan fails on any other account."
  validation {
    condition     = can(regex("^[0-9]{12}$", var.expected_account_id))
    error_message = "12자리 AWS 계정 ID를 입력하세요."
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
  description = "Lightsail plan. micro_3_0 = 1 GB RAM, 40 GB SSD, IPv4, 2 TB transfer, USD 7/month."
}
variable "allowed_cidrs" {
  type        = list(string)
  description = "IPv4 CIDRs allowed to reach SSH (22) and the web (80). Add new networks here."
  validation {
    condition = length(var.allowed_cidrs) > 0 && alltrue([
      for c in var.allowed_cidrs : can(cidrhost(c, 0)) && !endswith(c, "/0")
    ])
    error_message = "허용 IP는 1개 이상의 IPv4 CIDR이어야 하며 전체 공개(/0)는 허용하지 않습니다."
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
