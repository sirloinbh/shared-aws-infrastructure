# The Terraform user's own managed policies (#79). Terraform may change them because the one-time
# bootstrap (scripts/bootstrap-iam.sh) gave the user `terraform-iam-self`, and the permissions boundary
# `terraform-boundary` caps whatever these policies allow. Neither of those two is managed here:
# the user cannot edit them, by design. The user's first inline policy (docs/operations.md 1-2,
# step 2) also stays out of Terraform.
locals {
  terraform_user = "terraform-workout"
  # Each name has a policy document iam-policies/<name>.json. A new policy is a new file plus a name here.
  terraform_policies = toset([
    "terraform-app-files",
    "terraform-route53-dns",
    "terraform-server-ip",
    "terraform-state",
    "terraform-wiki-site",
  ])
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

# These policies were made by hand in the console before #79. The imports adopt them unchanged.
# On a brand-new account, where the policies do not exist yet, delete these two blocks before the first plan.
import {
  for_each = local.terraform_policies
  to       = aws_iam_policy.terraform[each.key]
  id       = "arn:aws:iam::${var.expected_account_id}:policy/${each.key}"
}

import {
  for_each = local.terraform_policies
  to       = aws_iam_user_policy_attachment.terraform[each.key]
  id       = "${local.terraform_user}/arn:aws:iam::${var.expected_account_id}:policy/${each.key}"
}
