# Phase 1 — Foundation

**Goal:** a VPC and an EKS cluster, created entirely by Terraform, plus the GitHub OIDC
identity that CI will use. No manual step anywhere.

**Depends on:** nothing · **Blocks:** Phase 2 (needs the cluster), Phase 3 (needs ECR + the OIDC role)

---

## Build order within this phase

```
1. State backend          →  nothing works without it
2. GitHub OIDC module     →  CI identity, independent of the cluster
3. VPC + subnets + NAT    →  EKS needs somewhere to live
4. EKS cluster + node group
5. ECR, Secrets Manager, Pod Identity agent
```

Steps 1 and 2 are independent of 3–5, so you can do them in parallel. Everything else is
strictly sequential.

---

## 1. State backend — first, not last

It is not optional and it is not the thing you add at the end. Every subsequent `apply`
depends on it.

```hcl
# bootstrap/state/backend.tf — concrete values only; a backend block cannot read variables
terraform {
  backend "s3" {
    bucket         = "myapp-tfstate-042617239394"
    key            = "bootstrap/terraform.tfstate"
    region         = "eu-central-1"
    dynamodb_table = "myapp-tflock"
    encrypt        = true
    kms_key_id     = "arn:aws:kms:eu-central-1:042617239394:key/..."
  }
}

# bootstrap/state/main.tf — the bucket name is derived, so it cannot collide
data "aws_caller_identity" "current" {}

locals {
  bucket_name = "${local.name_prefix}-tfstate-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket" "state" {
  bucket        = local.bucket_name
  lifecycle { prevent_destroy = true }   # deleting this destroys everything it tracks
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "locks" {
  name         = "myapp-tflock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"
}
```

Apply this **twice by hand** before wiring it to anything:

```bash
cd bootstrap/state
export AWS_PROFILE=myapp

terraform init -backend=false     # first: no backend, because the bucket does not exist yet
terraform apply                   # creates the bucket, KMS key, and lock table
terraform init -migrate-state     # second: now the backend can attach
terraform plan                    # "No changes"
```

The two-step is not optional. Terraform cannot write state to a bucket that does not exist
yet, so the first apply runs with local state and the second picks up the remote backend.
Delete the local `terraform.tfstate*` files afterwards — they hold the same plaintext secrets.

Three notes worth internalising:

- **The bucket name ends in the account ID.** A fixed name like `myapp-tfstate` is already
  owned by another account and the first apply fails with `409 BucketAlreadyExists` — S3
  names are global. The suffix makes the default collision-proof.
- **`prevent_destroy` on the state bucket.** Without it, one `terraform destroy` destroys
  every resource you own.
- **State contains secrets in plaintext.** You will confirm this in verification step 2.

---

## 2. The GitHub OIDC module

This is the security foundation of the entire CI design. Write it as its own module —
it is reused by every workflow, and it is the thing most likely to be got wrong.

```hcl
# modules/github-oidc/main.tf
variable "repo" { type = string }   # "ORG/REPO"
variable "branches" {
  type    = list(string)
  default = ["refs/heads/main"]
}

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

# ── ECR push role: cd.yml ─────────────────────────────────────────────
resource "aws_iam_role" "ci_ecr_push" {
  name = "myapp-ci-ecr-push"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        # THIS ONE LINE IS THE ENTIRE SECURITY MODEL.
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:${var.repo}:ref:refs/heads/main"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "ci_ecr_push" {
  name = "ecr-push-only"
  role = aws_iam_role.ci_ecr_push.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {   # push images
        Effect   = "Allow"
        Action   = ["ecr:PutImage", "ecr:InitiateLayerUpload",
                    "ecr:UploadLayerPart", "ecr:CompleteLayerUpload"]
        Resource = "${aws_ecr_repository.app.arn}/*"
      },
      {   # and obtain a login token, which requires * on the registry itself
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
    ]
  })
}
```

### The `sub` condition, explained properly

`sub` is a claim in the GitHub-issued JWT describing *what* is asking for credentials. It
takes these forms:

| Context | `sub` value |
| --- | --- |
| Push to a branch | `repo:ORG/REPO:ref:refs/heads/main` |
| Any branch, any workflow | `repo:ORG/REPO:*` |
| A workflow using `environment: production` | `repo:ORG/REPO:environment:production` |
| A fork pull request | `repo:CONTRIB/REPO:pull_request` |

So `repo:ORG/REPO:*` — which is what most tutorials show — means **any branch, in any
workflow in that repo, plus any workflow you later add** can assume the role. Add a workflow
with `pull_request_target` by accident and it inherits the role.

Two safe patterns:

```hcl
# narrow: one branch only
"token.actions.githubusercontent.com:sub" = "repo:${var.repo}:ref:refs/heads/main"

# broader but still safe: any branch, but only workflows that declare the environment
"token.actions.githubusercontent.com:sub" = "repo:${var.repo}:environment:production"
```

The second is safer than the first for multi-branch teams, because adding a workflow still
requires deliberately adding `environment:` to it.

### Roles to create now

Build all four in this phase, even though Phase 3 uses only some immediately. Adding them
later means re-editing the trust policy, and trust policies are where mistakes hide.

| Role | Used by | Scope |
| --- | --- | --- |
| `ci-ecr-push` | `cd.yml` | `ecr:PutImage` + upload actions on this repo only |
| `infra-plan` | `infra.yml` (PR job) | read-only: `ecr:DescribeImages`, `ec2:Describe*`, `eks:Describe*`, plus state read |
| `infra-apply` | `infra.yml` (apply job) | Terraform's full write surface — the dangerous one |
| `break-glass` | none | Break-glass only. Documented, never used routinely |

`infra-plan` and `infra-apply` must be **separate roles**. One combined role means any PR
that gets merged can write infrastructure.

### Verify before moving on

```bash
# In a workflow on main — must SUCCEED
- uses: aws-actions/configure-aws-credentials@v4
  with: { role-to-assume: arn:aws:iam::ACCT:role/myapp-ci-ecr-push }

# In a workflow on a feature branch — must FAIL with
#   "Not authorized to perform sts:AssumeRoleWithWebIdentity"
```

Do this from a real branch, with a real token. To debug a mismatch, print the claim:

```bash
# decode the OIDC token GitHub provides (available in the runner env during a job)
echo "$ACTIONS_ID_TOKEN_REQUEST_TOKEN" | cut -d. -f2 | base64 -d | jq .
```

If you skip this check you are shipping an open door, and you will not discover it until
someone walks through it.

---

## 3. VPC

2 AZs to start. `10.0.0.0/16`, `/20` public and `/24` private per AZ.

```hcl
# modules/vpc/main.tf  (abridged — the shape that matters)
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = { Name = "myapp-vpc" }
}

# Public subnets — NAT GW, and later the load balancer
resource "aws_subnet" "public" {
  for_each = local.azs   # ["eu-central-1a", "eu-central-1b"]
  vpc_id            = aws_vpc.main.id
  availability_zone = each.value
  cidr_block        = cidrsubnet("10.0.0.0/16", 4, index(local.azs, each.value))

  tags = { Name = "public-${each.key}", Tier = "public" }
}

# Private subnets — EKS nodes and every workload
resource "aws_subnet" "private" {
  for_each = local.azs
  vpc_id            = aws_vpc.main.id
  availability_zone = each.value
  cidr_block        = cidrsubnet("10.0.0.0/16", 8, index(local.azs, each.value))

  tags = { Name = "private-${each.key}", Tier = "private" }
}

# ONE nat gateway for MVP. Production wants one per AZ (~$97/mo).
resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[local.azs[0]].id
}

# Gateway endpoints — free, and they keep ECR/state traffic off NAT
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.eu-central-1.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = concat([for s in aws_subnet.public : s.id],
                              [for s in aws_subnet.private : s.id])
}

resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.eu-central-1.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = concat([for s in aws_subnet.public : s.id],
                              [for s in aws_subnet.private : s.id])
}
```

The gateway endpoints cost nothing and remove the S3/DynamoDB path from your NAT bill
entirely. Include them from the start — retrofitting them later means touching every route
table again.

### Security groups

```hcl
# Nodes: only the cluster SG on 443. Nothing from the internet.
resource "aws_security_group" "nodes" {
  name_prefix = "myapp-nodes-"
  vpc_id      = aws_vpc.main.id

  lifecycle { create_before_destroy = true }
}

# EKS API: the runner egress range must be here or CI's kubectl steps time out
resource "aws_vpc_security_group_ingress_rule" "eks_from_ci" {
  security_group_id = aws_security_group.cluster.id
  cidr_ipv4         = "0.0.0.0/0"      # tighten to your runner egress ranges in Level 2
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}
```

---

## 4. EKS

```hcl
# modules/eks/main.tf
resource "aws_eks_cluster" "main" {
  name     = "myapp-dev"
  role_arn = aws_iam_role.eks.arn
  version  = "1.31"                     # PIN IT. Never "latest".

  access_config {
    authentication_mode = "API"          # access entries, NOT aws-auth
    bootstrap_cluster_creator_admin_permissions = true
  }

  vpc_config {
    subnet_ids = var.private_subnet_ids  # control plane AND nodes in private subnets
    # BOTH must be true. See below.
    endpoint_public_access  = true
    endpoint_private_access = true
    public_access_cidrs     = ["0.0.0.0/0"]
  }

  depends_on = [aws_iam_role_policy_attachment.eks]
}

resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "main"
  node_role_arn   = aws_iam_role.nodes.arn
  subnet_ids      = var.private_subnet_ids

  instance_types = ["t3.medium"]
  ami_type       = "AL2023_x86_64_STANDARD"   # do not use Bottlerocket at MVP

  scaling_config {
    desired_size = 3
    min_size     = 2
    max_size     = 5
  }

  update_config {
    max_unavailable = 1
  }
}

# Pod Identity agent — required for in-cluster AWS access
resource "aws_eks_addon" "pod_identity_agent" {
  cluster_name             = aws_eks_cluster.main.name
  addon_name               = "eks-pod-identity-agent"
  resolve_conflicts_on_create = "OVERWRITE"
}
```

### The two settings people get wrong

**Both endpoint flags must be true.** GitHub-hosted runners execute outside your VPC. With
`endpoint_private_access = false`, any `kubectl` step in CI hangs until timeout. With both
true, the API is reachable from inside (fast) and from the internet (what the runner needs),
restricted by `public_access_cidrs`.

**`authentication_mode = "API"`.** This opts into EKS Access Entries and away from the
`aws-auth` ConfigMap, which AWS has deprecated. Most Terraform examples still write
`aws-auth`; using access entries is both correct now and a clear signal you are working
from current documentation.

### Access entry for your own admin user

```hcl
resource "aws_eks_access_entry" "admin" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = aws_iam_role.platform_admin.arn
  type          = "STANDARD"

  kubernetes_groups = ["platform-admins"]
}

resource "aws_eks_access_policy_association" "admin" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = aws_eks_access_entry.admin.principal_arn
  policy_name   = "AmazonEKSClusterAdminPolicy"
  access_scope {
    type = "cluster"
  }
}
```

You need an access entry to run `kubectl` at all. Note that access entries replace
`mapRoles` in `aws-auth` — including the entry AWS auto-creates for your node group, which
`API_AND_CONFIG_MAP` handles for you during migration but `API` mode does not.

### Pod Identity agent

The `eks-pod-identity-agent` addon is what makes in-cluster AWS access possible without
IRSA or node roles. Install it now even though Phase 1 does not use it — Phase 2's External
Secrets Operator needs it, and installing an addon later is another `terraform apply`.

### Do not enable control plane logs yet

This is deliberate. EKS control plane log types generate a lot of CloudWatch data, and you
want to switch them on in Level 2 *while watching the cost*. Discovering the bill after the
fact is the wrong way to learn about log retention.

---

## 5. Also in this phase

### ECR — with the two settings people skip

```hcl
resource "aws_ecr_repository" "app" {
  name                 = "myapp"
  image_tag_mutability = "IMMUTABLE"   # an image that can change under a tag is a lie
  encryption_configuration {
    encryption_type = "AES256"
  }
  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name
  policy = jsonencode({
    rules = [{
      priority = 1
      description = "Expire untagged images after 7 days"
      selection = { tagStatus = "untagged", countType = "sinceImagePushed", countUnit = "days", countNumber = 7 }
      action = { type = "expire" }
    }]
  })
}
```

`IMMUTABLE` is the setting that makes Image Updater trustworthy — it cannot silently
re-point a tag at different content. The lifecycle policy is what stops untagged builds
from accruing storage cost forever, and it is pure savings for two lines of config.

### Secrets Manager

Two entries: `dev/myapp/db` and `dev/myapp/redis`. Generate the values with
`random_password`; do not invent them by hand.

### KMS key

```hcl
resource "aws_kms_key" "main" {
  description             = "myapp data encryption"
  enable_key_rotation     = true
  deletion_window_in_days = 30
}
```

---

## Verify before moving on

Five checks, each catching a different class of mistake.

```bash
# 1. No manual step was needed
kubectl get nodes -o wide
#    all Ready, and every node in a PRIVATE subnet

# 2. State is clean and you know what it exposes
cd infra/envs/dev && terraform plan      # "No changes"
aws s3api get-bucket-versioning --bucket myapp-tfstate-042617239394
terraform state pull | grep -i password
#    -> this prints your DB password in plaintext. That is why the bucket needs
#       versioning + block_public_access + SSE-KMS, and why you never commit state.

# 3. Auth mode is what you think it is
aws eks describe-cluster --name myapp-dev   --query 'cluster.accessConfig.authenticationMode'
#    -> "API"

# 4. The OIDC boundary actually holds
#    -> succeeds on main, FAILS on a feature branch and on a fork PR

# 5. Pods can get AWS credentials via Pod Identity, not the node role
kubectl create ns app
#    create a service account, associate it with a role, run a pod with an AWS SDK
#    -> succeeds. kubectl exec into a pod with NO association
#    -> aws sts get-caller-identity FAILS. If it succeeds you are on the node role.
```

Check 5's second half is the one that catches the most common misconfiguration. If any pod
can call `sts:GetCallerIdentity` without a Pod Identity association, it is silently using
the node's IAM role, and that role may have far more permissions than you intended.

---

## Exit criteria

- [ ] State bucket created, versioned, public access blocked, `prevent_destroy` set
- [ ] `terraform plan` reports no changes on a second run
- [ ] VPC with 2 AZs, public + private subnets, 1 NAT gateway, S3 + DynamoDB gateway endpoints
- [ ] EKS cluster `Ready`, both endpoint flags true, `authentication_mode = "API"`
- [ ] 3 nodes `Ready`, all in private subnets
- [ ] Pod Identity agent installed
- [ ] Your IAM principal has an access entry — `kubectl` works
- [ ] ECR repo `IMMUTABLE` with scan-on-push + a lifecycle policy
- [ ] Two Secrets Manager entries created
- [ ] **OIDC verified: succeeds on `main`, fails on a feature branch and a fork PR**
- [ ] `terraform state pull | grep -i password` reviewed, and the state bucket is locked down accordingly

---

## Common failures

| Symptom | Cause | Fix |
| --- | --- | --- |
| Nodes `NotReady` | `AmazonEKS_CNI_Policy` not attached to the node role | Attach it, then recreate the node group |
| Nodes `NotReady` | Subnet tagging for the CNI missing | Tag subnets `kubernetes.io/role/elb=1` and `kubernetes.io/role/internal-elb=1` |
| `terraform init` says bucket does not exist | First apply not done yet | Apply `bootstrap/state` twice — you cannot write state to a bucket you have not created |
| Workflow fails at `configure-aws-credentials` | `sub` does not match the actual context | Decode the token, compare `sub` to your trust policy. `environment:` and `ref:` produce different values |
| Workflow fails with thumbprint error | Stale thumbprint list | Re-fetch from `https://api.github.com/meta` or drop the list — AWS now root-CA based |
| `kubectl` hangs in CI | Endpoint is private-only | Both flags must be true; add the runner CIDR to the cluster SG |
| `kubectl` denied | No access entry | Add one for your principal |
| Any pod can call `sts:GetCallerIdentity` | Node IAM role is too broad, or no Pod Identity association | Associate a service account + role; strip the node role of Secrets Manager access |

---

## Cost contribution

| Item | Monthly |
| --- | --- |
| EKS control plane | $73 |
| 3 × `t3.medium` (730h) | ~$100 |
| 1 NAT gateway (730h + data) | ~$33 |
| ECR + S3 + Secrets Manager + KMS | ~$2 |
| **Running total** | **~$208/mo** |

Gateway endpoints are free and will reduce the NAT data line once the cluster is busy.
Right-size to `t3.small` in Level 2 once Container Insights tells you what the app actually
uses.
