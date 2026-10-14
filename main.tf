variable "region" {
  type = string
  default = "ap-northeast-2"
}
variable "project" {
  type = string
  default = "shared-apps"
}
variable "budget_email" { type = string }
variable "monthly_budget_usd" {
  type = number
  default = 20
}
resource "aws_ecr_repository" "app" {
  for_each = toset(["workout-frontend", "workout-backend"])
  name = "${var.project}/${each.value}"
  image_tag_mutability = "IMMUTABLE"
  image_scanning_configuration { scan_on_push = true }
  encryption_configuration { encryption_type = "AES256" }
  tags = { Project = var.project }
}
resource "aws_ecr_lifecycle_policy" "app" {
  for_each = aws_ecr_repository.app
  repository = each.value.name
  policy = jsonencode({ rules = [{ rulePriority = 1, description = "Keep latest 10 images", selection = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 10 }, action = { type = "expire" } }] })
}
resource "aws_budgets_budget" "monthly" {
  name = "${var.project}-monthly"
  budget_type = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit = "USD"
  time_unit = "MONTHLY"
  notification {
    comparison_operator = "GREATER_THAN"
    threshold = 80
    threshold_type = "PERCENTAGE"
    notification_type = "ACTUAL"
    subscriber_email_addresses = [var.budget_email]
  }
}
output "repositories" { value = { for k, v in aws_ecr_repository.app : k => v.repository_url } }
