terraform {
  # 1.10 or later: the S3 backend's own lock file (use_lockfile) needs it.
  required_version = ">= 1.10.0"
  required_providers { aws = { source = "hashicorp/aws", version = "~> 6.68" } }
  # Remote state (#63). The bucket name holds the account ID and the profile is personal, so both
  # come from the git-ignored state.tfbackend (state.tfbackend.example):
  #   terraform init "-backend-config=state.tfbackend"
  # The bucket itself is state.tf; docs/operations.md section 3 has the first move and recovery.
  backend "s3" {
    key          = "shared-aws-infrastructure/terraform.tfstate"
    region       = "ap-northeast-2"
    encrypt      = true
    use_lockfile = true
  }
}
# CloudFront reads certificates only from us-east-1 (wiki.tf).
provider "aws" {
  alias   = "us_east_1"
  region  = "us-east-1"
  profile = var.aws_profile
}
