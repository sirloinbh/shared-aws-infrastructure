# One-time adoption of resources that already exist in AWS (#30). They were created on
# 2026-10-29, but that state is not in this folder, so a plan wanted to create them again and
# the apply failed with "already exists". These blocks add them to the state instead.
# Remove this file after the apply (the blocks do nothing once the resources are in the state).
locals {
  import_bucket = "sirloinbh-db-backups-${var.expected_account_id}"
}

import {
  to = aws_s3_bucket.backups
  id = local.import_bucket
}
import {
  to = aws_s3_bucket_public_access_block.backups
  id = local.import_bucket
}
import {
  to = aws_s3_bucket_ownership_controls.backups
  id = local.import_bucket
}
import {
  to = aws_s3_bucket_server_side_encryption_configuration.backups
  id = local.import_bucket
}
import {
  to = aws_s3_bucket_versioning.backups
  id = local.import_bucket
}
import {
  to = aws_s3_bucket_lifecycle_configuration.backups
  id = local.import_bucket
}
import {
  to = aws_s3_bucket_policy.backups
  id = local.import_bucket
}
import {
  to = aws_iam_user.backup_uploader
  id = "${local.shared_prefix}-backup-uploader"
}
import {
  to = aws_iam_user_policy.backup_uploader
  id = "${local.shared_prefix}-backup-uploader:put-db-dumps"
}
import {
  to = aws_iam_user.secrets_reader
  id = "${local.shared_prefix}-secrets-reader"
}
# The reader's policy in AWS still has its old name. Importing it lets the plan replace it with
# read-app-keys (#27) instead of leaving the old policy behind.
import {
  to = aws_iam_user_policy.secrets_reader
  id = "${local.shared_prefix}-secrets-reader:read-claude-key"
}
