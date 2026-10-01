# Step 1 explained — the GitHub OIDC trust boundary

Step 1 is the identity layer: the GitHub OIDC provider and the four IAM roles that workflows
assume instead of holding AWS access keys. It comes before any compute because every later
workflow — building images, planning, applying — depends on it, and because a mistake here
is an open door that nothing downstream will catch.

The commands and variables live in [`README.md`](README.md). This document explains *why* the
design is shaped the way it is.

---

## 1. The problem: a static secret that never expires

The usual way to let CI touch AWS is to create an IAM user, generate an access key, and paste
it into a GitHub secret. That key is a bearer token:

- it works from anywhere, not just from your repository;
- it works until someone remembers to rotate it;
- it is only as secret as every log, artifact, fork, and laptop that touches it;
- if it leaks, the only thing limiting the damage is the IAM policy — which is usually too
  broad because scoping it is tedious.

Rotating it is a manual, breakable process. There is no moment where the credential is
*inherently* limited to "this repository, this branch, right now".

## 2. What OIDC changes

Instead of a stored secret, GitHub acts as an identity provider. For each workflow run it
mints a short-lived JWT, signed by GitHub, containing claims about exactly what is running.

AWS is configured to trust GitHub's issuer. When a job asks for credentials:

1. the job requests a token from GitHub (`id-token: write` permission),
2. it presents that token to AWS STS (`AssumeRoleWithWebIdentity`),
3. AWS verifies the signature against GitHub's public keys and checks the claims,
4. STS returns temporary credentials valid for about an hour.

No AWS secret is stored in GitHub. The credential cannot be replayed outside the run it was
issued for, and cannot be used from a different repository or branch unless the trust policy
says so.

| Property | Static access key | OIDC |
| --- | --- | --- |
| Lifetime | until rotated | ~1 hour, per run |
| Replayable | yes, from anywhere | no |
| Bound to repo/branch | no | yes, by the `sub` claim |
| Lives in GitHub | yes, as a secret | no |
| Rotation | manual | none needed |

## 3. The claims AWS checks

The token carries three claims that matter here:

| Claim | Value for this repo | Checks |
| --- | --- | --- |
| `iss` (issuer) | `https://token.actions.githubusercontent.com` | which provider's key signed it |
| `aud` (audience) | `sts.amazonaws.com` | it was minted for AWS, not some other service |
| `sub` (subject) | see below | *what* is running |

The trust policy requires both an `aud` match and a `sub` match. The `aud` condition is not
optional: without it, a token GitHub minted for a *different* audience would be accepted.

## 4. Why `sub` is the entire security model

`sub` describes the context asking for credentials. Its form depends on what triggered the
run:

| Context | `sub` |
| --- | --- |
| Push to a branch | `repo:ORG@OWNER_ID/REPO@REPO_ID:ref:refs/heads/main` |
| Any branch, any workflow | `repo:ORG@OWNER_ID/REPO@REPO_ID:*` |
| A job using `environment: production` | `repo:ORG@OWNER_ID/REPO@REPO_ID:environment:production` |
| A pull request | `repo:ORG@OWNER_ID/REPO@REPO_ID:pull_request` |
| A fork pull request | `repo:CONTRIB@ID/REPO@ID:pull_request` |

The `*` form is what most tutorials show. It lets **any branch and any workflow you add
later** assume the role — so adding a workflow that uses `pull_request_target` quietly
extends the trust. This module never uses it.

Two patterns are used instead, depending on the role:

- **one branch** — `...:ref:refs/heads/main` for the push role;
- **one environment** — `...:environment:production` for the apply role.

The environment form is the stronger pattern for teams: a new workflow still has to
deliberately declare `environment: production` to gain access, and that is where required
reviewers are enforced.

The fork case is worth noting for the plan role: a PR from a fork carries the *contributor's*
`ORG/REPO`, never yours, so it can never match your `pull_request` condition.

## 5. The immutable `@ID` suffixes — the trap that looks correct

GitHub now appends immutable numeric IDs to the owner and repository in `sub`:

```
repo:Bishoy-Samwel@29541335/eks-github-actions-gitops@1399970615:ref:refs/heads/main
```

A policy written the old way, `repo:ORG/REPO:...`, **never matches**, and every assume fails
with:

```
Not authorized to perform sts:AssumeRoleWithWebIdentity
```

This is the most confusing failure in the whole setup, because the policy *looks* perfectly
correct and the error sounds like a permissions problem. In this project it was caught by
running the workflow and decoding the token, not by reading the config.

Get the IDs with:

```bash
gh api repos/ORG/REPO --jq '{owner_id:.owner.id, repo_id:.id}'
```

and pass them as `repo_subject` (`ORG@OWNER_ID/REPO@REPO_ID`). Trusting the IDs is also safer
than trusting names: a repository can be renamed, or deleted and its name reused by someone
else, but its ID is permanent. The name-only form can be re-pointed at a different repository;
the ID form cannot.

## 6. Four roles, not one

The module creates four roles with deliberately different blast radii:

| Role | Assumed by | Trusted `sub` | Scope |
| --- | --- | --- | --- |
| `myapp-ci-ecr-push` | image build/push | `ref:refs/heads/main` | push to one ECR repository |
| `myapp-infra-plan` | PR plan job | `pull_request` | read-only describes + state read |
| `myapp-infra-apply` | apply job | `environment:production` | Terraform's write surface |
| `myapp-break-glass` | a human | MFA required | AdministratorAccess, never routine |

The important split is `infra-plan` vs `infra-apply`. If they were one role, then read access
granted to every pull request would also be write access — any merged PR could change
infrastructure. Keeping them separate means a plan runs on the read-only role, and only a
gated apply can write.

`infra-apply` gets `PowerUserAccess` (everything except IAM and account management) plus a
narrow inline policy for the IAM actions Terraform legitimately needs — creating roles,
attaching policies, and passing roles to services. It is intentionally not
`AdministratorAccess`.

`break-glass` exists so there is a documented path for the rare human case, protected only by
an MFA condition on assumption. It is not referenced by any workflow.

## 7. What it creates

| Resource | Name / ARN |
| --- | --- |
| OIDC provider | `arn:aws:iam::042617239394:oidc-provider/token.actions.githubusercontent.com` |
| ECR push role | `arn:aws:iam::042617239394:role/myapp-ci-ecr-push` |
| Plan role | `arn:aws:iam::042617239394:role/myapp-infra-plan` |
| Apply role | `arn:aws:iam::042617239394:role/myapp-infra-apply` |
| Break-glass role | `arn:aws:iam::042617239394:role/myapp-break-glass` |

The provider is one per AWS account, not per environment. The first environment creates it;
later ones look it up with `create_oidc_provider = false`.

## 8. What breaks without it

| If you skip… | What goes wrong |
| --- | --- |
| OIDC entirely | long-lived keys that never rotate, stored in GitHub |
| the `aud` condition | tokens minted for other audiences are accepted |
| a narrow `sub` | any branch or any workflow you add can assume the role |
| the immutable `@ID` form | every assume fails as `Not authorized`, looking like a permissions bug |
| separate plan/apply roles | every PR can write infrastructure |
| the `environment:` condition | the apply role is reachable without the review gate |
| MFA on break-glass | the most powerful role is assumable with a bare token |

## 9. Cost

The OIDC provider, IAM roles, and inline policies are all free. Step 1 adds **$0.00/month**.

## 10. Verifying it

**Static** — the policy says what you think:

```bash
aws iam get-role --role-name myapp-ci-ecr-push \
  --query 'Role.AssumeRolePolicyDocument.Statement[0].Condition'
aws iam get-open-id-connect-provider \
  --open-id-connect-provider-arn arn:aws:iam::042617239394:oidc-provider/token.actions.githubusercontent.com \
  --query '{Url:Url,Audience:ClientIDList}'
```

**Dynamic** — the only real test. A workflow that assumes the role:

- on `main` must **succeed**;
- on any other branch must **fail** with `Not authorized`.

To see what token you actually got, decode it during a run:

```bash
TOKEN=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=sts.amazonaws.com" | jq -r .value)
echo "$TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null | jq '{iss, aud, sub}'
```

Until the branch case *fails*, the boundary is unproven — a policy that is too permissive
still passes the success case.

## 11. The one thing it does not fix

OIDC proves *which repository, branch, or environment* is asking. It says nothing about
whether the code in that workflow is safe to run with those permissions. A workflow on `main`
can still be changed by anyone who can merge to `main`, and `infra-apply` is a genuinely
powerful role. The boundary limits *who* can act; branch protection and required reviews limit
*what code* acts.

## Next

[Phase 1 step 2 — the VPC](../../01-mvp/phase-1-foundation.md), which the apply role will
create.
