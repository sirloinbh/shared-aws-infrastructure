# Off-server copies of the nightly app database dumps (#7, project-standards#262).
# The server uploads with deploy/backup.sh of each app; its key can only add objects, so a
# leaked key cannot read, list or delete backups. Versioning keeps an overwritten dump.
module "backups" {
  source     = "./modules/private_bucket"
  name       = "sirloinbh-db-backups-${data.aws_caller_identity.current.account_id}"
  tags       = local.tags
  depends_on = [terraform_data.account_guard]
  lifecycle_rule = {
    id              = "expire-dumps"
    expiration_days = var.offsite_backup_days
    noncurrent_days = var.offsite_backup_days
  }
}

# Moved into modules/private_bucket (#80); these keep the existing bucket and its settings.
moved {
  from = aws_s3_bucket.backups
  to   = module.backups.aws_s3_bucket.this
}

moved {
  from = aws_s3_bucket_public_access_block.backups
  to   = module.backups.aws_s3_bucket_public_access_block.this
}

moved {
  from = aws_s3_bucket_ownership_controls.backups
  to   = module.backups.aws_s3_bucket_ownership_controls.this
}

moved {
  from = aws_s3_bucket_server_side_encryption_configuration.backups
  to   = module.backups.aws_s3_bucket_server_side_encryption_configuration.this
}

moved {
  from = aws_s3_bucket_versioning.backups
  to   = module.backups.aws_s3_bucket_versioning.this[0]
}

moved {
  from = aws_s3_bucket_lifecycle_configuration.backups
  to   = module.backups.aws_s3_bucket_lifecycle_configuration.this
}

moved {
  from = aws_s3_bucket_policy.backups
  to   = module.backups.aws_s3_bucket_policy.this
}

# The server's upload-only identity. Its access key is made in the console (docs/operations.md)
# so the secret never enters the Terraform state.
resource "aws_iam_user" "backup_uploader" {
  name                 = "${local.shared_prefix}-backup-uploader"
  permissions_boundary = local.terraform_server_user_boundary
  tags                 = local.tags
  depends_on           = [terraform_data.account_guard]
}

resource "aws_iam_user_policy" "backup_uploader" {
  name = "put-db-dumps"
  user = aws_iam_user.backup_uploader.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "PutOnly"
      Effect   = "Allow"
      Action   = "s3:PutObject"
      Resource = "${module.backups.arn}/*"
    }]
  })
}
