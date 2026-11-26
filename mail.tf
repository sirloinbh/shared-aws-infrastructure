# Email for study-log (#120, sirloinbh/study-log#365): the daily review reminder is sent through
# AWS SES from one verified address. SES is regional, so everything is in var.region. The identity is
# an email address: AWS mails a verification link to it once, and it stays pending until clicked
# (docs/operations.md section 10). A new SES account is in the sandbox, which also limits recipients
# to verified addresses, so the reminder goes to the same address it is sent from.
# The identity waits for terraform-app-mail to be attached to the Terraform user.
resource "aws_sesv2_email_identity" "study_log_mail" {
  email_identity = var.study_log_mail_address
  tags           = local.tags
  depends_on     = [terraform_data.account_guard, aws_iam_user_policy_attachment.terraform["terraform-app-mail"]]
}

# The server's mail identity: it can send from this one address and do nothing else in SES (no
# SendRawEmail, no identity or quota changes, no other sender). Its access key is made in the
# console (docs/operations.md section 10) so the secret never enters the Terraform state; rotation
# follows #104. study-log reads it from SES_AWS_ACCESS_KEY_ID and SES_AWS_SECRET_ACCESS_KEY, because
# AWS_ACCESS_KEY_ID in the same .env is the files user.
resource "aws_iam_user" "study_log_mail" {
  name                 = "${local.shared_prefix}-study-log-mail"
  permissions_boundary = local.terraform_server_user_boundary
  tags                 = local.tags
  depends_on           = [terraform_data.account_guard]
}

resource "aws_iam_user_policy" "study_log_mail" {
  name = "send-study-log-mail"
  user = aws_iam_user.study_log_mail.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "SendFromTheIdentity"
        Effect   = "Allow"
        Action   = "ses:SendEmail"
        Resource = aws_sesv2_email_identity.study_log_mail.arn
        Condition = {
          StringEquals = { "ses:FromAddress" = var.study_log_mail_address }
        }
      },
    ]
  })
}
