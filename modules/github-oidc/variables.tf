variable "repo" {
  description = "GitHub repository in ORG/REPO form whose workflows may assume the CI roles."
  type        = string

  validation {
    condition     = can(regex("^[^/]+/[^/]+$", var.repo))
    error_message = "repo must be in ORG/REPO form, e.g. \"Bishoy-Samwel/eks-github-actions-gitops\"."
  }
}

variable "name_prefix" {
  description = "Prefix for every IAM role and policy this module creates."
  type        = string
  default     = "myapp"
}

variable "create_oidc_provider" {
  description = <<-EOT
    Create the GitHub OIDC provider.

    The provider is one per AWS ACCOUNT, never per environment. On the first environment
    created in an account leave this true; on every later environment set it false so the
    module looks the existing provider up instead of trying to create a second one (AWS
    allows only one provider per URL and the second apply fails).
  EOT
  type        = bool
  default     = true
}

variable "main_branch" {
  description = "Git ref (without the refs/heads/ prefix) that trusted push workflows run on."
  type        = string
  default     = "main"
}

variable "apply_environment" {
  description = <<-EOT
    GitHub Environment the apply role is gated on. The apply job in the workflow must
    declare `environment: <name>`, otherwise the OIDC subject will not match and the
    assume-role call fails.
  EOT
  type        = string
  default     = "production"
}

variable "ecr_repository_arn" {
  description = <<-EOT
    ARN of the ECR repository the CI push role may write images to. Leave empty to skip
    the push statement, e.g. when this module is applied before the repository exists.
    Set it once the repository exists and re-apply to grant the push actions.
  EOT
  type        = string
  default     = ""
}

variable "state_bucket_arn" {
  description = <<-EOT
    ARN of the Terraform state bucket. The plan role is granted read access to it. Leave
    empty to skip, e.g. before the bucket exists.
  EOT
  type        = string
  default     = ""
}

variable "infra_apply_policy_arns" {
  description = <<-EOT
    Managed policy ARNs attached to the apply role, in addition to the inline IAM policy
    this module adds.

    The default is PowerUserAccess (everything except IAM and account management) plus a
    scoped inline IAM policy for the role/policy/OIDC actions Terraform needs. This is
    deliberately narrower than AdministratorAccess, which is what most tutorials attach.
    Widen only with a reason.
  EOT
  type        = list(string)
  default     = ["arn:aws:iam::aws:policy/PowerUserAccess"]
}

variable "break_glass_principals" {
  description = <<-EOT
    IAM principal ARNs allowed to assume the break-glass role. Empty means the account
    root. Assumption always requires MFA.
  EOT
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags applied to every resource this module creates."
  type        = map(string)
  default     = {}
}
