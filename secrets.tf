# Read access to the shared Claude API key in SSM Parameter Store (#8, project-standards ADR-0010).
# The parameter itself is not managed here: Terraform would read its decrypted value into the
# state on every refresh. `node tools/app-secrets.mjs set` in project-standards creates and
# replaces it. Apps with features.claude read it at deploy time with deploy/ssm-get.sh.
locals {
  claude_key_parameter     = "/sirloinbh/anthropic-api-key"
  claude_key_parameter_arn = "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter${local.claude_key_parameter}"
}

# The server's read-only identity. Its access key is made in the console (docs/operations.md).
resource "aws_iam_user" "secrets_reader" {
  name       = "${var.project}-secrets-reader"
  tags       = local.tags
  depends_on = [terraform_data.account_guard]
}

# A SecureString under the AWS managed key (alias/aws/ssm) is decrypted through SSM, so
# ssm:GetParameter on this one parameter is the whole permission.
resource "aws_iam_user_policy" "secrets_reader" {
  name = "read-claude-key"
  user = aws_iam_user.secrets_reader.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "ReadOneParameter"
      Effect   = "Allow"
      Action   = "ssm:GetParameter"
      Resource = local.claude_key_parameter_arn
    }]
  })
}
