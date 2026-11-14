# Read access to the app keys in SSM Parameter Store (#8, #27, project-standards ADR-0010 and
# ADR-0014). Keys several apps share live under /sirloinbh/shared/, one app's keys under
# /sirloinbh/<app>/. The parameters themselves are not managed here: Terraform would read their
# decrypted values into the state on every refresh. `node tools/app-secrets.mjs set <parameter>`
# in project-standards creates and replaces them. App deploy scripts read the keys their
# .env.example tags with @ssm= (deploy/ssm-get.sh).
locals {
  # Apps whose own keys the server may read. Add an app here when it gets its first own key.
  secret_apps          = ["workout-memo", "study-log", "health-log", "life-journal", "money-ledger", "cert-manager", "plan-routine", "dev-career-portfolio"]
  parameter_arn_prefix = "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/sirloinbh"
  secret_parameter_arns = concat(
    ["${local.parameter_arn_prefix}/shared/*"],
    [for app in local.secret_apps : "${local.parameter_arn_prefix}/${app}/*"],
  )
}

# The server's read-only identity. Its access key is made in the console (docs/operations.md).
resource "aws_iam_user" "secrets_reader" {
  name       = "${local.shared_prefix}-secrets-reader"
  tags       = local.tags
  depends_on = [terraform_data.account_guard]
}

# A SecureString under the AWS managed key (alias/aws/ssm) is decrypted through SSM, so
# ssm:GetParameter on these paths is the whole permission (no list, no write).
resource "aws_iam_user_policy" "secrets_reader" {
  name = "read-app-keys"
  user = aws_iam_user.secrets_reader.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "ReadAppKeys"
      Effect   = "Allow"
      Action   = "ssm:GetParameter"
      Resource = local.secret_parameter_arns
    }]
  })
}
