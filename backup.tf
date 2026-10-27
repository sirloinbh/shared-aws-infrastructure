# Off-server copies of the nightly app database dumps (#7, project-standards#262).
# The server uploads with deploy/backup.sh of each app; its key can only add objects, so a
# leaked key cannot read, list or delete backups. Versioning keeps an overwritten dump.
resource "aws_s3_bucket" "backups" {
  bucket     = "sirloinbh-db-backups-${data.aws_caller_identity.current.account_id}"
  tags       = local.tags
  depends_on = [terraform_data.account_guard]
}

resource "aws_s3_bucket_public_access_block" "backups" {
  bucket                  = aws_s3_bucket.backups.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "backups" {
  bucket = aws_s3_bucket.backups.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "backups" {
  bucket = aws_s3_bucket.backups.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  bucket     = aws_s3_bucket.backups.id
  depends_on = [aws_s3_bucket_versioning.backups]
  rule {
    id     = "expire-dumps"
    status = "Enabled"
    filter {}
    expiration {
      days = var.offsite_backup_days
    }
    noncurrent_version_expiration {
      noncurrent_days = var.offsite_backup_days
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

# HTTPS only.
resource "aws_s3_bucket_policy" "backups" {
  bucket     = aws_s3_bucket.backups.id
  depends_on = [aws_s3_bucket_public_access_block.backups]
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.backups.arn, "${aws_s3_bucket.backups.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}

# The server's upload-only identity. Its access key is made in the console (docs/operations.md)
# so the secret never enters the Terraform state.
resource "aws_iam_user" "backup_uploader" {
  name       = "${var.project}-backup-uploader"
  tags       = local.tags
  depends_on = [terraform_data.account_guard]
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
      Resource = "${aws_s3_bucket.backups.arn}/*"
    }]
  })
}
