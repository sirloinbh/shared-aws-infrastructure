# The Terraform user's own managed policies (#79). Terraform may change them because the one-time
# bootstrap (scripts/bootstrap-iam.sh) gave the user `terraform-iam-self`, and the permissions boundary
# `terraform-boundary` caps whatever these policies allow. Neither of those two is managed here:
# the user cannot edit them, by design. The user's first inline policy (docs/operations.md 1-2,
# step 2) also stays out of Terraform.
locals {
  terraform_user = "terraform-workout"
  # Each name has a policy document iam-policies/<name>.json. A new policy is a new file plus a name here.
  # The five made by hand before #79 are adopted by the import blocks below; a policy added after that is
  # created by Terraform, so it must not be imported (the import would fail on a policy that does not exist).
  terraform_imported_policies = toset([
    "terraform-app-files",
    "terraform-route53-dns",
    "terraform-server-ip",
    "terraform-state",
    "terraform-wiki-site",
  ])
  terraform_policies = setunion(local.terraform_imported_policies, [
    "terraform-uptime-alerts",
    "terraform-cost-anomaly",
  ])
  # The boundary every role that Terraform creates must carry (#85). The bootstrap makes it, and
  # terraform-boundary refuses to create a role, or write its policy, without it.
  terraform_role_boundary = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/terraform-role-boundary"
  # The boundary every server user (sirloinbh-apps-*) must carry (#88). The bootstrap makes it, and
  # terraform-boundary refuses to create a server user, or write its inline policy, without it.
  terraform_server_user_boundary = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/terraform-server-user-boundary"
}

resource "aws_iam_policy" "terraform" {
  for_each = local.terraform_policies
  name     = each.key
  policy   = file("${path.module}/iam-policies/${each.key}.json")
  # A description typed in the console would otherwise force a replacement on import.
  lifecycle {
    ignore_changes = [description]
  }
}

resource "aws_iam_user_policy_attachment" "terraform" {
  for_each   = local.terraform_policies
  user       = local.terraform_user
  policy_arn = aws_iam_policy.terraform[each.key].arn
}

# The policies in terraform_imported_policies were made by hand in the console before #79. The imports adopt them unchanged.
# On a brand-new account, where the policies do not exist yet, delete these two blocks before the first plan.
import {
  for_each = local.terraform_imported_policies
  to       = aws_iam_policy.terraform[each.key]
  id       = "arn:aws:iam::${var.expected_account_id}:policy/${each.key}"
}

import {
  for_each = local.terraform_imported_policies
  to       = aws_iam_user_policy_attachment.terraform[each.key]
  id       = "${local.terraform_user}/arn:aws:iam::${var.expected_account_id}:policy/${each.key}"
}
