terraform {
  required_version = ">= 1.7.0"
  required_providers { aws = { source = "hashicorp/aws", version = "~> 6.68" } }
}
# Personal account only: pass the profile explicitly so a company default profile is never used.
provider "aws" {
  region  = var.region
  profile = var.aws_profile
}
# CloudFront reads certificates only from us-east-1 (wiki.tf).
provider "aws" {
  alias   = "us_east_1"
  region  = "us-east-1"
  profile = var.aws_profile
}
