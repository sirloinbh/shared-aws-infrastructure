# Account-wide guard rails (#97). Every bucket in this repo already blocks public access through
# modules/private_bucket; this block also covers a bucket made outside that module, by hand or by a
# new resource. The wiki is not affected: CloudFront reads it with origin access control and a bucket
# policy for the cloudfront.amazonaws.com service principal, which this setting does not block.
resource "aws_s3_account_public_access_block" "this" {
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
  depends_on              = [terraform_data.account_guard]
}
