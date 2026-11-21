variable "name" {
  description = "The bucket name."
  type        = string
}

variable "tags" {
  description = "Tags on the bucket."
  type        = map(string)
}

variable "versioning" {
  description = "Keep earlier versions of overwritten and deleted objects."
  type        = bool
  default     = true
}

variable "lifecycle_rule" {
  description = <<-EOT
    The bucket's one lifecycle rule. expiration_days expires current objects,
    expire_delete_markers removes delete markers that have no versions left, noncurrent_days
    and newer_noncurrent_versions expire earlier versions. Leave a field unset to omit it.
  EOT
  type = object({
    id                        = string
    expiration_days           = optional(number)
    expire_delete_markers     = optional(bool, false)
    noncurrent_days           = optional(number)
    newer_noncurrent_versions = optional(number)
  })
}

variable "policy_statements" {
  description = "Extra bucket policy statements, placed before the HTTPS-only deny."
  # Statements differ in shape (Principal, Condition), so a list type would not unify them.
  type    = any
  default = []
}
