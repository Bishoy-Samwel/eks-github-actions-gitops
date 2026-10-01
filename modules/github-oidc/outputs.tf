output "oidc_provider_arn" {
  description = "ARN of the GitHub OIDC provider (created or looked up)."
  value       = local.oidc_provider_arn
}

output "ci_ecr_push_role_arn" {
  description = "Role assumed by the image build/push job. Pass to configure-aws-credentials as role-to-assume."
  value       = aws_iam_role.ci_ecr_push.arn
}

output "infra_plan_role_arn" {
  description = "Read-only role assumed by the pull_request plan job."
  value       = aws_iam_role.infra_plan.arn
}

output "infra_apply_role_arn" {
  description = "Write role assumed by the apply job, gated on the GitHub Environment."
  value       = aws_iam_role.infra_apply.arn
}

output "break_glass_role_arn" {
  description = "Break-glass role. MFA required; not used by any routine workflow."
  value       = aws_iam_role.break_glass.arn
}
