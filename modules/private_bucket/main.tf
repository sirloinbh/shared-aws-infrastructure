# A private S3 bucket (#80): no public access, objects owned by the bucket owner, SSE-S3
# encryption, optional versioning, one lifecycle rule, and a policy that denies plain HTTP.
# Every bucket in this repo comes from here, so these settings are written once.
terraform {
  required_providers {
    aws = { source = "hashicorp/aws" }
  }
}

resource "aws_s3_bucket" "this" {
  bucket = var.name
  tags   = var.tags
  lifecycle {
    # Every bucket here holds data that is lost with it (DB dump copies, app files, the
    # Terraform state) or is served from it (the wiki). prevent_destroy cannot come from a
    # variable, so it holds for all of them; to remove a bucket, see docs/operations.md.
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket                  = aws_s3_bucket.this.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "this" {
  bucket = aws_s3_bucket.this.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "this" {
  count  = var.versioning ? 1 : 0
  bucket = aws_s3_bucket.this.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Unset fields stay null, so the rule has only the blocks and attributes the caller asked for.
# Failed multipart uploads are always cleaned up after a day.
resource "aws_s3_bucket_lifecycle_configuration" "this" {
  bucket     = aws_s3_bucket.this.id
  depends_on = [aws_s3_bucket_versioning.this]
  rule {
    id     = var.lifecycle_rule.id
    status = "Enabled"
    filter {}
    dynamic "noncurrent_version_expiration" {
      for_each = var.lifecycle_rule.noncurrent_days == null ? [] : [var.lifecycle_rule]
      content {
        noncurrent_days           = noncurrent_version_expiration.value.noncurrent_days
        newer_noncurrent_versions = noncurrent_version_expiration.value.newer_noncurrent_versions
      }
    }
    dynamic "expiration" {
      for_each = var.lifecycle_rule.expiration_days == null && !var.lifecycle_rule.expire_delete_markers ? [] : [var.lifecycle_rule]
      content {
        days                         = expiration.value.expiration_days
        expired_object_delete_marker = expiration.value.expire_delete_markers ? true : null
      }
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

# The caller's statements come first, then HTTPS only for everyone.
resource "aws_s3_bucket_policy" "this" {
  bucket     = aws_s3_bucket.this.id
  depends_on = [aws_s3_bucket_public_access_block.this]
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(var.policy_statements, [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.this.arn, "${aws_s3_bucket.this.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }])
  })
}
