# Original PDF and photo files of study-log exercises (#53, sirloinbh/study-log#28). The app
# stores each upload under exercises/<exercise id>/<uuid>.<ext> and reads and deletes it by key.
# Versioning keeps a deleted or overwritten file for var.app_file_recovery_days (user decision,
# 2026-11-17), so a delete in the app can be undone by hand.
resource "aws_s3_bucket" "study_log_files" {
  bucket     = "sirloinbh-study-log-files-${data.aws_caller_identity.current.account_id}"
  tags       = local.tags
  depends_on = [terraform_data.account_guard]
}

resource "aws_s3_bucket_public_access_block" "study_log_files" {
  bucket                  = aws_s3_bucket.study_log_files.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "study_log_files" {
  bucket = aws_s3_bucket.study_log_files.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "study_log_files" {
  bucket = aws_s3_bucket.study_log_files.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "study_log_files" {
  bucket = aws_s3_bucket.study_log_files.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Current files stay until the app deletes them; only earlier versions and delete markers expire.
resource "aws_s3_bucket_lifecycle_configuration" "study_log_files" {
  bucket     = aws_s3_bucket.study_log_files.id
  depends_on = [aws_s3_bucket_versioning.study_log_files]
  rule {
    id     = "expire-deleted-files"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = var.app_file_recovery_days
    }
    expiration {
      expired_object_delete_marker = true
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

# HTTPS only.
resource "aws_s3_bucket_policy" "study_log_files" {
  bucket     = aws_s3_bucket.study_log_files.id
  depends_on = [aws_s3_bucket_public_access_block.study_log_files]
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.study_log_files.arn, "${aws_s3_bucket.study_log_files.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}

# The server's identity for these files: get, put and delete objects, which is all the app calls.
# ListBucket only makes S3 answer a missing file with NoSuchKey (the app's 404) instead of
# AccessDenied (its 503 about credentials); the key can read every file anyway. No bucket settings,
# so a leaked key cannot turn off versioning or delete earlier versions. Its access key is made in
# the console (docs/operations.md), as for the other users.
resource "aws_iam_user" "study_log_files" {
  name       = "${local.shared_prefix}-study-log-files"
  tags       = local.tags
  depends_on = [terraform_data.account_guard]
}

resource "aws_iam_user_policy" "study_log_files" {
  name = "study-log-files"
  user = aws_iam_user.study_log_files.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "Objects"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.study_log_files.arn}/*"
      },
      {
        Sid      = "MissingIsNotFound"
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = aws_s3_bucket.study_log_files.arn
      },
    ]
  })
}
