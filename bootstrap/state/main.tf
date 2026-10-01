// Step 0 — Terraform state backend.
//
// This is the only part of the infrastructure that cannot be created by Terraform
// pointing at remote state, so it is created with local state and then migrated.
// See README.md for the two-apply flow.
//
// Everything here is deliberately boring and deliberately locked down. The state file
// contains every resource attribute, including secrets in plaintext, so its bucket is
// treated as a credential store rather than as scratch space.

// The account ID is what makes the default bucket name safe. Without it, a fixed name
// like "myapp-tfstate" is already owned by someone else and every apply fails with
// BucketAlreadyExists.
data "aws_caller_identity" "current" {}

locals {
  name_prefix = "myapp"
  bucket_name = var.bucket_name != "" ? var.bucket_name : "${local.name_prefix}-tfstate-${data.aws_caller_identity.current.account_id}"
}

// ─── KMS key ────────────────────────────────────────────────────────────────────
// SSE-S256 (AES256) would be the simpler choice, but it uses AWS-managed keys: you
// cannot see their access in CloudTrail, you cannot control when they are deleted, and
// you cannot tell who decrypted what. A customer-managed key gives you the audit trail
// and an explicit rotation policy.

resource "aws_kms_key" "state" {
  description             = "Encrypts ${aws_s3_bucket.state.id} Terraform state at rest"
  enable_key_rotation     = true
  deletion_window_in_days = 30

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-tfstate"
  })
}

resource "aws_kms_alias" "state" {
  name          = "alias/${local.name_prefix}-tfstate"
  target_key_id = aws_kms_key.state.key_id
}

// ─── State bucket ───────────────────────────────────────────────────────────────

resource "aws_s3_bucket" "state" {
  bucket = local.bucket_name

  // Without this, a single `terraform destroy` in any other config that shares this
  // backend removes the state for everything. Terraform will refuse instead.
  lifecycle {
    prevent_destroy = true
  }

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-tfstate"
  })
}

// Ownership: S3 defaults to BucketOwnerPreferred, which lets another account set
// object ownership. For a state bucket we want no ambiguity about who owns what.
resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    # This is what makes a bad apply recoverable. Without versioning, a corrupted
    # state overwrite is unrecoverable.
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    bucket_key_enabled = true

    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.state.arn
    }
  }
}

// Keep old versions long enough to recover from, then stop paying for them.
resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_expiration_days
    }
  }

  rule {
    id     = "abort-incomplete-multipart-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Bucket policy: deny anything that is not TLS. Without this, a misconfigured legacy
// client can put state on the wire in plaintext.
data "aws_iam_policy_document" "state_bucket" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]

    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state_bucket.json

  # The policy references the bucket ARN, and the bucket must exist first.
  depends_on = [aws_s3_bucket_public_access_block.state]
}

// ─── Lock table ──────────────────────────────────────────────────────────────────
// Terraform writes state without a lock check unless the backend declares one. Two
// concurrent applies interleave their reads and writes, and the resulting state can
// name resources that never existed. This table is what prevents that.

resource "aws_dynamodb_table" "locks" {
  name         = var.lock_table_name
  billing_mode = "PAY_PER_REQUEST"

  # PAY_PER_REQUEST: no provisioned capacity to guess at, and no cost when idle.
  # An under-provisioned lock table fails acquires, which fails your deploys.

  hash_key = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-tflock"
  })
}
