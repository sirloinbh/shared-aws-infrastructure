# Remote Terraform state (#63). This configuration creates the bucket while the state is still
# local; the backend block that moves the state here comes in a later change, after the bucket
# exists (docs/operations.md section 3). Versioning keeps every earlier state, so a bad apply or
# a deleted state object can be rolled back.
resource "aws_s3_bucket" "terraform_state" {
  bucket     = "sirloinbh-terraform-state-${data.aws_caller_identity.current.account_id}"
  tags       = local.tags
  depends_on = [terraform_data.account_guard]
  lifecycle {
    # Deleting this bucket deletes the state of everything else here.
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_public_access_block" "terraform_state" {
  bucket                  = aws_s3_bucket.terraform_state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id
  versioning_configuration {
    status = "Enabled"
  }
}

# The current state stays forever. Earlier versions expire after var.state_version_days, but the
# newest 20 of them are always kept, so a quiet month never leaves the state without history.
# The lock file (.tflock) is created and deleted on every run; its leftovers expire the same way.
resource "aws_s3_bucket_lifecycle_configuration" "terraform_state" {
  bucket     = aws_s3_bucket.terraform_state.id
  depends_on = [aws_s3_bucket_versioning.terraform_state]
  rule {
    id     = "expire-old-states"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days           = var.state_version_days
      newer_noncurrent_versions = 20
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
resource "aws_s3_bucket_policy" "terraform_state" {
  bucket     = aws_s3_bucket.terraform_state.id
  depends_on = [aws_s3_bucket_public_access_block.terraform_state]
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.terraform_state.arn, "${aws_s3_bucket.terraform_state.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}
