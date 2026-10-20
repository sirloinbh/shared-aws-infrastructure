terraform {
  required_version = ">= 1.6.0"
  required_providers { aws = { source = "hashicorp/aws", version = "~> 5.0" } }
}
# Personal account only: pass the profile explicitly so a company default profile is never used.
provider "aws" {
  region  = var.region
  profile = var.aws_profile
}
