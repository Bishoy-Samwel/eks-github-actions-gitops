// Values the other Terraform configs need in order to point at this backend.
// Nothing sensitive here: the bucket is locked to this account via its IAM policy,
// and access comes from the caller's credentials, not from anything in the backend block.

output "state_bucket_name" {
  description = "Bucket name to use in the backend block of every environment config."
  value       = aws_s3_bucket.state.id
}

output "state_bucket_arn" {
  description = "ARN of the state bucket."
  value       = aws_s3_bucket.state.arn
}

output "lock_table_name" {
  description = "DynamoDB table name to use as dynamodb_table in the backend block."
  value       = aws_dynamodb_table.locks.name
}

output "kms_key_arn" {
  description = "KMS key encrypting state at rest. Needed if you read state outside Terraform."
  value       = aws_kms_key.state.arn
}

output "region" {
  description = "Region the backend lives in. Must match every environment config."
  value       = var.region
}

output "backend_config" {
  description = "Copy-paste backend block for an environment config."
  value       = <<-EOT
    backend "s3" {
      bucket         = "${aws_s3_bucket.state.id}"
      key            = "REPLACE_ME/terraform.tfstate"
      region         = "${var.region}"
      dynamodb_table = "${aws_dynamodb_table.locks.name}"
      encrypt        = true
      kms_key_id     = "${aws_kms_key.state.arn}"
    }
  EOT
}
