# env: dev

The composition root for the dev environment. It contains the [GitHub OIDC
module](../../../modules/github-oidc/README.md) from step 1 and the [VPC
module](../../../modules/vpc/README.md) from step 2. EKS, ECR, and Secrets Manager are added
here in later steps of [Phase 1](../../../01-mvp/phase-1-foundation.md).

Everything in this directory is applied with the remote state created in `bootstrap/state`
(`key = "dev/terraform.tfstate"`), so the first `init` needs the state bucket to already
exist.

## Run it

```bash
cd infra/envs/dev
export AWS_PROFILE=myapp

terraform init
terraform plan
terraform apply
```

## What it creates

Step 1 — identity (free):

| Resource | Name |
| --- | --- |
| GitHub OIDC provider | `token.actions.githubusercontent.com` |
| ECR push role | `myapp-ci-ecr-push` |
| PR plan role | `myapp-infra-plan` |
| Apply role | `myapp-infra-apply` |
| Break-glass role | `myapp-break-glass` |

Step 2 — network:

| Resource | Name |
| --- | --- |
| VPC | `myapp-vpc` (`10.0.0.0/16`) |
| Public subnets | `10.0.0.0/20`, `10.0.16.0/20` in the first two AZs |
| Private subnets | `10.0.128.0/20`, `10.0.144.0/20` |
| NAT gateway | `myapp-nat-0`, shared by both private subnets |
| Gateway endpoints | S3 and DynamoDB, attached to every route table |

The roles are keyed to this repository (`Bishoy-Samwel/eks-github-actions-gitops`, override
with `-var github_repo=...`) and are useless to any other repo.

## Outputs

| Output | Use |
| --- | --- |
| `ci_ecr_push_role_arn` | `role-to-assume` in the image build/push workflow |
| `infra_plan_role_arn` | `role-to-assume` in the PR plan job |
| `infra_apply_role_arn` | `role-to-assume` in the apply job |
| `break_glass_role_arn` | Human break-glass access |
| `oidc_provider_arn` | Reference / debugging |
| `state_bucket_name` | The bucket this environment uses |

## Ordering note

The apply role is gated on the GitHub Environment named by `apply_environment`
(default `production`). Create that environment in the repository settings before using the
apply workflow, or its OIDC subject will not match and the assume call will fail.

`ecr_repository_arn` is passed as `""` for now. Once the ECR repository exists (later in
Phase 1), set it in `main.tf` and re-apply so `ci-ecr-push` gains its push actions.

## Verify

```bash
# Roles exist
for r in ci-ecr-push infra-plan infra-apply break-glass; do
  aws iam get-role --role-name "myapp-$r" --query 'Role.Arn' --output text
done

# The trust boundary (must match the intended sub — see the module README)
aws iam get-role --role-name myapp-ci-ecr-push \
  --query 'Role.AssumeRolePolicyDocument.Statement[0].Condition'
```

A workflow run on `main` (succeeds) versus a feature branch (fails) is the only real test of
the boundary. See the verification section of the module README.

## Cost

| Step | Items | Monthly |
| --- | --- | --- |
| 1 — identity | OIDC provider, roles, policies | $0.00 |
| 2 — network | NAT gateway (730h) + data | ~$33 |
| | VPC, subnets, IGW, gateway endpoints | $0.00 |

The NAT gateway is the first recurring cost in the project and is billed whether or not
anything uses it.
