variable "region" {
  description = "AWS region hosting the state bucket and lock table. Must match every environment."
  type        = string
  default     = "eu-west-1"
}

variable "bucket_name" {
  description = <<-EOT
    Globally unique S3 bucket name for Terraform state.
    S3 bucket names are global, so this must be unique across all AWS accounts.
  EOT
  type        = string
  default     = "myapp-tfstate"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.bucket_name))
    error_message = "Bucket name must be 3-63 lowercase characters, and must not look like an IP address."
  }
}

variable "lock_table_name" {
  description = "DynamoDB table used for Terraform state locking."
  type        = string
  default     = "myapp-tflock"
}

variable "noncurrent_version_expiration_days" {
  description = <<-EOT
    Days to retain noncurrent state versions before S3 expires them.
    Old versions are your recovery path from a bad apply, so keep this comfortably
    above the number of applies you might need to walk back.
  EOT
  type        = number
  default     = 90
}

variable "tags" {
  description = "Tags applied to the state bucket, lock table, and KMS key."
  type        = map(string)
  default = {
    Project   = "myapp"
    ManagedBy = "terraform"
    Component = "bootstrap"
  }
}
