# Remote Terraform state (#63). This configuration creates the bucket while the state is still
# local; the backend block that moves the state here comes in a later change, after the bucket
# exists (docs/operations.md section 3). Versioning keeps every earlier state, so a bad apply or
# a deleted state object can be rolled back.
# Deleting this bucket deletes the state of everything else here; the module sets prevent_destroy.
# The current state stays forever. Earlier versions expire after var.state_version_days, but the
# newest 20 of them are always kept, so a quiet month never leaves the state without history.
# The lock file (.tflock) is created and deleted on every run; its leftovers expire the same way.
module "terraform_state" {
  source     = "./modules/private_bucket"
  name       = "sirloinbh-terraform-state-${data.aws_caller_identity.current.account_id}"
  tags       = local.tags
  depends_on = [terraform_data.account_guard]
  lifecycle_rule = {
    id                        = "expire-old-states"
    noncurrent_days           = var.state_version_days
    newer_noncurrent_versions = 20
    expire_delete_markers     = true
  }
}

# Moved into modules/private_bucket (#80); these keep the existing bucket and its settings.
moved {
  from = aws_s3_bucket.terraform_state
  to   = module.terraform_state.aws_s3_bucket.this
}

moved {
  from = aws_s3_bucket_public_access_block.terraform_state
  to   = module.terraform_state.aws_s3_bucket_public_access_block.this
}

moved {
  from = aws_s3_bucket_ownership_controls.terraform_state
  to   = module.terraform_state.aws_s3_bucket_ownership_controls.this
}

moved {
  from = aws_s3_bucket_server_side_encryption_configuration.terraform_state
  to   = module.terraform_state.aws_s3_bucket_server_side_encryption_configuration.this
}

moved {
  from = aws_s3_bucket_versioning.terraform_state
  to   = module.terraform_state.aws_s3_bucket_versioning.this[0]
}

moved {
  from = aws_s3_bucket_lifecycle_configuration.terraform_state
  to   = module.terraform_state.aws_s3_bucket_lifecycle_configuration.this
}

moved {
  from = aws_s3_bucket_policy.terraform_state
  to   = module.terraform_state.aws_s3_bucket_policy.this
}
