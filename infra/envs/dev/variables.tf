variable "region" {
  description = "AWS region for this environment. Must match the state backend's region."
  type        = string
  default     = "eu-central-1"
}

variable "name_prefix" {
  description = "Prefix for resource names and IAM roles created in this environment."
  type        = string
  default     = "myapp"
}

variable "github_repo" {
  description = "GitHub repository in ORG/REPO form allowed to assume the CI roles."
  type        = string
  default     = "Bishoy-Samwel/eks-github-actions-gitops"
}

variable "main_branch" {
  description = "Branch that trusted push workflows run on."
  type        = string
  default     = "main"
}

variable "apply_environment" {
  description = <<-EOT
    GitHub Environment the apply role is gated on. The apply job must declare
    `environment: <name>` or its OIDC subject will not match the trust policy.
  EOT
  type        = string
  default     = "production"
}

variable "create_oidc_provider" {
  description = <<-EOT
    Create the GitHub OIDC provider. True for the first environment in an account; false
    for every later one, where the provider already exists and is looked up instead.
  EOT
  type        = bool
  default     = true
}

variable "state_bucket_name" {
  description = <<-EOT
    Name of the Terraform state bucket, used to grant the plan role read access. Leave
    empty to derive "myapp-tfstate-<account-id>", matching bootstrap/state.
  EOT
  type        = string
  default     = ""
}
