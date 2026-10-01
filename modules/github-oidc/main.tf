data "aws_caller_identity" "current" {}

// ─── The GitHub OIDC provider ───────────────────────────────────────────────────
//
// GitHub mints a short-lived JWT for each workflow run. AWS trusts the token's issuer,
// verifies it was meant for AWS (aud), and verifies the subject (sub) matches. No
// long-lived AWS access key ever exists, which is the whole point of using OIDC.

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 1 : 0

  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]

  tags = var.tags
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 0 : 1

  url = "https://token.actions.githubusercontent.com"
}

locals {
  oidc_provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn

  // What the token's `sub` carries between `repo:` and the context suffix. Normally the
  // immutable OWNER@ID/REPO@ID form, which is what GitHub issues now.
  repo_subject = var.repo_subject != "" ? var.repo_subject : var.repo

  // Every trust policy starts from this and adds a `sub` restriction. The audience check
  // is not optional: without it a token minted for any other audience would be accepted.
  trust_conditions = {
    StringEquals = {
      "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
    }
  }
}

// ─── ci-ecr-push: build and push an image from main ─────────────────────────────

resource "aws_iam_role" "ci_ecr_push" {
  name = "${var.name_prefix}-ci-ecr-push"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = local.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = merge(local.trust_conditions, {
        // Only a push to main. A feature branch, a PR, or a workflow added later cannot
        // assume this. This one line is the security model.
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:${local.repo_subject}:ref:refs/heads/${var.main_branch}"
        }
      })
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "ci_ecr_push" {
  name = "ecr-push-only"
  role = aws_iam_role.ci_ecr_push.id

  policy = jsonencode({
    Version = "2012-10-17"
    // The repository may not exist yet when this module first applies (ECR is created
    // later in the same environment). Until ecr_repository_arn is set, the role can only
    // obtain a registry token, which grants no access on its own.
    Statement = concat(
      var.ecr_repository_arn == "" ? [] : [
        {
          // Push and pull layer/image actions, scoped to this one repository.
          Effect = "Allow"
          Action = [
            "ecr:BatchCheckLayerAvailability",
            "ecr:BatchGetImage",
            "ecr:CompleteLayerUpload",
            "ecr:GetDownloadUrlForLayer",
            "ecr:InitiateLayerUpload",
            "ecr:PutImage",
            "ecr:UploadLayerPart",
          ]
          Resource = var.ecr_repository_arn
        },
      ],
      [
        {
          // Getting a registry token is an account-wide action with no resource scope, so
          // it must be "*". It grants no access on its own — the statement above decides
          // which repository the token can actually be used against.
          Effect   = "Allow"
          Action   = ["ecr:GetAuthorizationToken"]
          Resource = "*"
        },
      ],
    )
  })
}

// ─── infra-plan: read-only, for pull requests ───────────────────────────────────

resource "aws_iam_role" "infra_plan" {
  name = "${var.name_prefix}-infra-plan"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = local.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = merge(local.trust_conditions, {
        // Only workflows triggered by a pull_request event. Note a *fork* PR has the
        // subject `repo:CONTRIB/REPO:pull_request`, so it does not match this — forks
        // cannot read this account's state.
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:${local.repo_subject}:pull_request"
        }
      })
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "infra_plan" {
  name = "plan-read-only"
  role = aws_iam_role.infra_plan.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Effect = "Allow"
          Action = [
            "ec2:Describe*",
            "eks:Describe*",
            "eks:List*",
            "ecr:Describe*",
            "ecr:List*",
            "elasticloadbalancing:Describe*",
            "autoscaling:Describe*",
            "iam:Get*",
            "iam:List*",
            "logs:Describe*",
            "logs:List*",
            "kms:Describe*",
            "kms:List*",
          ]
          Resource = "*"
        },
      ],
      // Read the state file so a plan can be produced. Locking is skipped in CI with
      // `-lock=false`, so this role is not granted the DynamoDB lock verbs.
      var.state_bucket_arn == "" ? [] : [
        {
          Effect   = "Allow"
          Action   = ["s3:GetObject"]
          Resource = "${var.state_bucket_arn}/*"
        },
        {
          Effect   = "Allow"
          Action   = ["s3:ListBucket"]
          Resource = var.state_bucket_arn
        },
      ],
    )
  })
}

// ─── infra-apply: Terraform's write surface, gated on an environment ────────────

resource "aws_iam_role" "infra_apply" {
  name = "${var.name_prefix}-infra-apply"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = local.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = merge(local.trust_conditions, {
        // Gated on a GitHub Environment rather than a branch. Even a push to main cannot
        // assume this; the job must explicitly declare `environment: <apply_environment>`,
        // which is where required reviewers / branch rules are enforced.
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:${local.repo_subject}:environment:${var.apply_environment}"
        }
      })
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "infra_apply" {
  count = length(var.infra_apply_policy_arns)

  role       = aws_iam_role.infra_apply.name
  policy_arn = var.infra_apply_policy_arns[count.index]
}

resource "aws_iam_role_policy" "infra_apply_iam" {
  name = "iam-and-pass-role"
  role = aws_iam_role.infra_apply.id

  // The PowerUserAccess default excludes IAM, but Terraform has to create roles, attach
  // policies, and pass roles to services (EKS node roles, Pod Identity associations).
  // That is the one gap this policy fills; it does not grant account-level actions.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "iam:Get*",
        "iam:List*",
        "iam:CreateRole",
        "iam:DeleteRole",
        "iam:UpdateAssumeRolePolicy",
        "iam:AttachRolePolicy",
        "iam:DetachRolePolicy",
        "iam:PutRolePolicy",
        "iam:DeleteRolePolicy",
        "iam:TagRole",
        "iam:UntagRole",
        "iam:PassRole",
        "iam:CreatePolicy",
        "iam:DeletePolicy",
        "iam:CreatePolicyVersion",
        "iam:DeletePolicyVersion",
        "iam:TagPolicy",
        "iam:CreateOpenIDConnectProvider",
        "iam:DeleteOpenIDConnectProvider",
        "iam:TagOpenIDConnectProvider",
        "iam:CreateInstanceProfile",
        "iam:DeleteInstanceProfile",
        "iam:AddRoleToInstanceProfile",
        "iam:RemoveRoleFromInstanceProfile",
        "iam:CreateServiceLinkedRole",
      ]
      Resource = "*"
    }]
  })
}

// ─── break-glass: never used routinely, always MFA ──────────────────────────────

data "aws_iam_policy_document" "break_glass_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type = "AWS"
      identifiers = length(var.break_glass_principals) > 0 ? var.break_glass_principals : [
        "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
      ]
    }

    condition {
      test     = "Bool"
      variable = "aws:MultiFactorAuthPresent"
      values   = ["true"]
    }
  }
}

resource "aws_iam_role" "break_glass" {
  name               = "${var.name_prefix}-break-glass"
  assume_role_policy = data.aws_iam_policy_document.break_glass_assume.json

  tags = merge(var.tags, { Purpose = "break-glass" })
}

resource "aws_iam_role_policy_attachment" "break_glass" {
  role       = aws_iam_role.break_glass.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}
