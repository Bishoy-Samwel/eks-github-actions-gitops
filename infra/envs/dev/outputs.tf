output "oidc_provider_arn" {
  description = "GitHub OIDC provider ARN, created or looked up."
  value       = module.github_oidc.oidc_provider_arn
}

output "ci_ecr_push_role_arn" {
  description = "Role ARN for the image build/push job. Used as role-to-assume in cd.yml."
  value       = module.github_oidc.ci_ecr_push_role_arn
}

output "infra_plan_role_arn" {
  description = "Read-only role ARN for the pull_request plan job."
  value       = module.github_oidc.infra_plan_role_arn
}

output "infra_apply_role_arn" {
  description = "Write role ARN, gated on the GitHub Environment."
  value       = module.github_oidc.infra_apply_role_arn
}

output "break_glass_role_arn" {
  description = "Break-glass role ARN. MFA required; no routine workflow uses it."
  value       = module.github_oidc.break_glass_role_arn
}

output "state_bucket_name" {
  description = "State bucket this environment reads from and writes to."
  value       = local.state_bucket_name
}

output "vpc_id" {
  description = "VPC created for this environment."
  value       = module.vpc.vpc_id
}

output "public_subnet_ids" {
  description = "Public subnets: NAT gateway and load balancers."
  value       = module.vpc.public_subnet_ids
}

output "private_subnet_ids" {
  description = "Private subnets: EKS control plane, nodes, and pods."
  value       = module.vpc.private_subnet_ids
}

output "cluster_name" {
  description = "EKS cluster name these subnets are tagged for."
  value       = local.cluster_name
}
