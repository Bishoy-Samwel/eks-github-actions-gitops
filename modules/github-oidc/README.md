# module: github-oidc

The GitHub Actions trust boundary for this account. It creates the GitHub OIDC identity
provider and the four IAM roles that workflows assume instead of long-lived access keys.

```hcl
module "github_oidc" {
  source = "../../../modules/github-oidc"

  repo              = "ORG/REPO"
  state_bucket_arn  = "arn:aws:s3:::myapp-tfstate-<account-id>"
  ecr_repository_arn = ""   # set once ECR exists
}
```

## Why OIDC instead of access keys

An IAM user's access key is a bearer token that never expires until someone rotates it. If
it leaks from a workflow, a log, or a fork, it works from anywhere until you notice.

GitHub can instead mint a short-lived JWT for each workflow run, signed by GitHub, that
states exactly what is running. AWS verifies the signature against GitHub's public keys and
checks the token's claims. The credential is valid for minutes and cannot be replayed from
outside the run it was issued for. No AWS secret is ever stored in GitHub.

## The four roles

| Role | Assumed by | Condition on `sub` | Scope |
| --- | --- | --- | --- |
| `ci-ecr-push` | image build/push workflow | `ref:refs/heads/main` | push images to one ECR repo |
| `infra-plan` | PR plan job | `pull_request` | read-only describes + state read |
| `infra-apply` | apply job | `environment:production` | Terraform's write surface |
| `break-glass` | a human, by hand | MFA required | AdministratorAccess — not used by CI |

`infra-plan` and `infra-apply` are deliberately separate roles. One combined role would mean
any merged PR could write infrastructure.

## The `sub` condition is the security model

Every role's trust policy requires *both* claims:

- `aud` = `sts.amazonaws.com` — the token was minted for AWS, and
- `sub` = a specific string — this exact context is running.

`sub` takes different forms depending on what triggered the run:

| Context | `sub` |
| --- | --- |
| Push to a branch | `repo:ORG/REPO:ref:refs/heads/main` |
| Any branch, any workflow | `repo:ORG/REPO:*` |
| A job using `environment: production` | `repo:ORG/REPO:environment:production` |
| A pull request | `repo:ORG/REPO:pull_request` |
| A fork pull request | `repo:CONTRIB/REPO:pull_request` |

`repo:ORG/REPO:*` — what most tutorials show — lets *any* branch and *any workflow you add
later* assume the role. That is the mistake this module exists to avoid.

The fork case matters for `infra-plan`: a fork PR carries the *contributor's* `ORG/REPO`,
not yours, so it can never match your `pull_request` condition.

## One provider per account

AWS allows a single OIDC provider per issuer URL per account. The module handles this:

- `create_oidc_provider = true` (default) — first environment in the account creates it.
- `create_oidc_provider = false` — later environments look the existing provider up.

Apply a second environment with the default and it fails: the provider already exists.

## `ecr_repository_arn` is optional

The build/push role needs to know which repository it may write to, but that repository is
created after this module in the build order. Leave the variable empty on the first apply:
the role then holds only `ecr:GetAuthorizationToken`, which grants no access on its own. Set
the ARN and re-apply once ECR exists to grant the push actions.

## Inputs

| Name | Default | Description |
| --- | --- | --- |
| `repo` | — | `ORG/REPO` whose workflows may assume the roles |
| `name_prefix` | `myapp` | Prefix for role and policy names |
| `create_oidc_provider` | `true` | Create the provider, or look up the existing one |
| `main_branch` | `main` | Branch trusted for push workflows |
| `apply_environment` | `production` | GitHub Environment gating the apply role |
| `ecr_repository_arn` | `""` | Repository the push role may write to |
| `state_bucket_arn` | `""` | State bucket the plan role may read |
| `infra_apply_policy_arns` | `["arn:aws:iam::aws:policy/PowerUserAccess"]` | Managed policies for the apply role |
| `break_glass_principals` | `[]` | Principals allowed to assume break-glass (default: account root) |
| `tags` | `{}` | Tags applied to every resource |

## Outputs

| Name | Use |
| --- | --- |
| `oidc_provider_arn` | Reference / debugging |
| `ci_ecr_push_role_arn` | `role-to-assume` in the build/push workflow |
| `infra_plan_role_arn` | `role-to-assume` in the PR plan job |
| `infra_apply_role_arn` | `role-to-assume` in the apply job |
| `break_glass_role_arn` | Human break-glass access |

## Verifying the boundary

Static check — the trust policy says what you think it says:

```bash
aws iam get-role --role-name myapp-ci-ecr-push \
  --query 'Role.AssumeRolePolicyDocument.Statement[0].Condition'
```

Real check — a workflow run is the only thing that exercises the full path:

1. On `main`, `configure-aws-credentials` with `ci-ecr-push` must **succeed**.
2. On any other branch, the same step must **fail** with
   `Not authorized to perform sts:AssumeRoleWithWebIdentity`.

Until that second case fails, the trust boundary is unproven.

## Gotchas

- **`environment:` must be declared** in the apply job or its `sub` will not match
  `environment:production` and the assume call fails.
- **Thumbprint.** AWS now manages the GitHub thumbprint; the value here is the historical
  one and AWS will update it if needed. An error mentioning thumbprints means the list is
  stale — re-fetch from `https://api.github.com/meta`.
- **Break-glass is AdministratorAccess.** Keep it off every workflow; its only protection is
  the MFA condition on assumption.
