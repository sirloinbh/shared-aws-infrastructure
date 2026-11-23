# Audit trail (#102, epic #97). One multi-region trail keeps the account's management events in a
# private S3 bucket, so the actions of a leaked key can be traced past the 90 days of the default
# event history. The first trail that records management events is free; only the S3 storage costs
# a little. Data events and Insights are not recorded (they are billed). Where to read the logs and
# the cost: docs/operations.md section 14.
locals {
  cloudtrail_name = "sirloinbh-audit"
  # Written out, not read from the trail, because the bucket policy must exist before the trail.
  cloudtrail_arn            = "arn:aws:cloudtrail:${var.region}:${data.aws_caller_identity.current.account_id}:trail/${local.cloudtrail_name}"
  cloudtrail_log_bucket     = "sirloinbh-cloudtrail-logs-${data.aws_caller_identity.current.account_id}"
  cloudtrail_retention_days = 365
}

# Only the CloudTrail service may write, only for this trail (aws:SourceArn), and only under this
# account's AWSLogs prefix. Versioning is off: log files are written once and never overwritten.
module "cloudtrail_logs" {
  source     = "./modules/private_bucket"
  name       = local.cloudtrail_log_bucket
  tags       = local.tags
  versioning = false
  depends_on = [terraform_data.account_guard]
  lifecycle_rule = {
    id              = "expire-trail-logs"
    expiration_days = local.cloudtrail_retention_days
  }
  policy_statements = [
    {
      Sid       = "CloudTrailAclCheck"
      Effect    = "Allow"
      Principal = { Service = "cloudtrail.amazonaws.com" }
      Action    = "s3:GetBucketAcl"
      Resource  = "arn:aws:s3:::${local.cloudtrail_log_bucket}"
      Condition = { StringEquals = { "aws:SourceArn" = local.cloudtrail_arn } }
    },
    {
      Sid       = "CloudTrailWrite"
      Effect    = "Allow"
      Principal = { Service = "cloudtrail.amazonaws.com" }
      Action    = "s3:PutObject"
      Resource  = "arn:aws:s3:::${local.cloudtrail_log_bucket}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
      Condition = {
        StringEquals = {
          "aws:SourceArn" = local.cloudtrail_arn
          "s3:x-amz-acl"  = "bucket-owner-full-control"
        }
      }
    },
  ]
}

resource "aws_cloudtrail" "audit" {
  name                          = local.cloudtrail_name
  s3_bucket_name                = module.cloudtrail_logs.id
  is_multi_region_trail         = true
  include_global_service_events = true
  enable_log_file_validation    = true
  tags                          = local.tags

  # Management events only, reads and writes. No data events, so the trail stays free.
  event_selector {
    read_write_type           = "All"
    include_management_events = true
  }
}

output "cloudtrail_log_bucket" {
  description = "The S3 bucket that holds the CloudTrail log files."
  value       = module.cloudtrail_logs.bucket
}
