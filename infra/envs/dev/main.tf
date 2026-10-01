data "aws_caller_identity" "current" {}

locals {
  tags = {
    Project     = var.name_prefix
    Environment = "dev"
    ManagedBy   = "terraform"
  }

  // Same derivation as bootstrap/state, so the bucket name cannot drift between the two.
  state_bucket_name = var.state_bucket_name != "" ? var.state_bucket_name : "${var.name_prefix}-tfstate-${data.aws_caller_identity.current.account_id}"
}

// ─── Step 1: GitHub OIDC identity ───────────────────────────────────────────────
//
// The provider and the four roles. This is the trust boundary every later workflow
// depends on, so it is applied and verified before any of the compute it will manage.

module "github_oidc" {
  source = "../../../modules/github-oidc"

  repo                 = var.github_repo
  name_prefix          = var.name_prefix
  create_oidc_provider = var.create_oidc_provider
  main_branch          = var.main_branch
  apply_environment    = var.apply_environment

  // The ECR repository does not exist yet at step 1. Set this once it does and re-apply
  // to grant ci-ecr-push its push actions.
  ecr_repository_arn = ""

  // Without this the plan role cannot read state and `terraform plan` in CI fails.
  state_bucket_arn = "arn:aws:s3:::${local.state_bucket_name}"

  tags = local.tags
}
