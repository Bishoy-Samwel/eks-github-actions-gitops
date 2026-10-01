# New AWS account setup

The order to do things in when starting from a brand new AWS account, before running any
Terraform in this repo.

Step 0 of [Phase 1](../01-mvp/phase-1-foundation.md) needs working credentials and a billing
alarm. Nothing here is infrastructure — it is all account-level setup, done once.

---

## Two decisions to make first

**Region.** Everything lives in one region: the state bucket, the VPC, the EKS cluster, and
the `aws-region` value in every workflow. Decide now, because changing it later means
rebuilding the state bucket and moving the cluster.

**Root account email.** New accounts default to a personal email. Set a company alias and
enable MFA before anything else.

---

## 1 — Root account MFA

Console → account name → Security credentials → enable MFA.

Do this first, alone. Every later step assumes you cannot be permanently locked out, and
it takes two minutes. Doing it after creating IAM users risks an interruption where you
cannot re-authenticate.

---

## 2 — Decide how you authenticate

This determines steps 3 and 4, so it goes early.

| Approach | Use when | Trade-off |
| --- | --- | --- |
| IAM Identity Center (SSO) | Beyond a few days of work, or a team | More setup, but no long-lived keys and easy revocation |
| IAM user + access keys | Learning, throwaway account, short project | Fast to start; keys need rotating by hand |

For a learning account that will live a couple of months, an IAM user is the pragmatic
choice. Be clear-eyed about it though: those keys are a long-lived credential with no
expiry. If they leak, whoever holds them owns everything in the account — including the
EKS cluster and NAT gateways generating real charges. That is a real risk, not a
theoretical one.

---

## 3 — Create the admin user

IAM → Users → Create user → name it `admin` (or anything; the name is only for humans).

Attach `AdministratorAccess` for now. When the CI roles from Phase 1 exist, replace it with
a policy scoped to the specific resources Terraform touches: S3 state, DynamoDB lock, KMS,
`iam:CreateRole` + `iam:PassRole`, EKS, ECR.

Writing that policy before the resource ARNs exist produces one of two bad outcomes: a
policy that blocks your own deploys, or one that grants everything anyway. There is no
reason to rush it.

Note this is a **user**, not a role. The wrong shape on purpose: this account uses GitHub
OIDC for CI, and Terraform runs on your workstation, not on an EC2 instance — so there is
no instance profile involved anywhere.

---

## 4 — Credentials on your machine

Two paths. Prefer the first.

**Option A — console credentials (recommended).** If the user was created with **console
access** and AWS CLI >= 2.32.0, there is no access key to store at all:

```bash
aws login --profile myapp     # browser flow, valid up to 12h, auto-refreshes
aws sts get-caller-identity --profile myapp
```

Requires the `SignInLocalDevelopmentAccess` managed policy on the user. Check your version
with `aws --version`.

**Option B — access keys.** Create a key in the IAM console, download the CSV, then:

```bash
./bootstrap/scripts/setup-aws-profile.sh --csv ~/Downloads/accessKeys.csv --profile myapp
```

The script writes the profile without printing the secret or putting it in your shell
history. Which file gets written, how to verify, and how to rotate: [`CREDENTIALS.md`](CREDENTIALS.md).

To do it by hand instead:

```bash
aws configure set aws_access_key_id     "AKIA..." --profile myapp
aws configure set aws_secret_access_key "..."     --profile myapp
aws configure set region eu-central-1             --profile myapp
```

Either way, export the profile:

```bash
export AWS_PROFILE=myapp
```

Named profile, not `[default]`, for two reasons: the existing `[default]` keys in this
environment were already rejected by STS, and if they ever do work you would have no way
to run account-admin commands separately.

Never commit these keys. They live outside the repo, and `.gitignore` blocks `*.tfvars` and
`.env` as a backstop. Delete the downloaded CSV once the profile is written — a plaintext
secret in a downloads folder is the most common way these leak.

The user also needs `AdministratorAccess` attached (step 3), or `terraform apply` fails at
the first resource with `AccessDenied`.

---

## 5 — Billing: budget alarm and Cost Explorer

Billing → Billing preferences → enable Cost Explorer if it is not already on. New
accounts sometimes ship with it disabled, which leaves the budget console with nothing to
chart against.

Billing → Budgets → create one: **$50 monthly, alerts at 80% and 100%**, email to yourself.

Then check free tier terms. In the current program EC2 covers a `t3.micro` for 12
months, but **NAT gateway hours, load balancer hours, and CloudWatch log ingestion are
not free tier eligible**, and EKS control plane free-tier treatment is time-limited and
region-dependent. Verify the current terms rather than assuming — the control plane is
$73/month on its own and is the largest single line in this project.

Set the alarm **before** the first `terraform apply`. An alarm set afterwards may fire
after the billing period has already closed.

---

## 6 — Leave the default VPC alone

A new account comes with a default VPC, public subnets, and an internet gateway. It is
free, it costs nothing to keep, and deleting it gains nothing.

Phase 1 builds its own VPC with a documented subnet layout. The cluster should live in
something designed, not in the account default.

---

## 7 — Confirm identity and region

```bash
aws sts get-caller-identity
aws configure list --profile myapp
```

The first must print `Account`, `Arn`, and `UserId`. If it prints `InvalidClientTokenId`,
everything downstream fails with the same error, so this is the gate.

---

## 8 — Apply step 0

```bash
cd bootstrap/state
export AWS_PROFILE=myapp

terraform init -backend=false   # the bucket does not exist yet, so no backend
terraform apply                 # bucket + KMS key + lock table
terraform init -migrate-state   # move local state into the bucket
terraform state list
```

Then verify — the full list is in [`bootstrap/state/README.md`](state/README.md):

```bash
B=$(terraform output -raw state_bucket_name)   # myapp-tfstate-<account-id>
aws s3api get-public-access-block --bucket "$B"
aws s3api get-bucket-versioning   --bucket "$B"
aws dynamodb describe-table       --table-name myapp-tflock
```

The bucket name ends in your account ID. A fixed name like `myapp-tfstate` is owned by
someone else and fails the first apply with `409 BucketAlreadyExists` — accounts are unique,
so putting the account ID in the name is what makes the default safe.

---

## Why this order

Steps 5 before 8: an alarm created after the first apply may fire after the bill has
already closed, and `prevent_destroy` blocks a mistaken *destroy* but not a mistaken
*creation*.

Step 2 before 4: the credential shape decides whether you hold a long-lived key to rotate.
Much cheaper to choose now than after the first workflow authenticates with it.

Step 1 before everything: it is the only step that cannot be recovered from.

---

## Checklist

- [ ] Root MFA enabled
- [ ] Region chosen and consistent
- [ ] Auth method chosen (SSO or IAM user)
- [ ] `terraform-admin` user created
- [ ] `AdministratorAccess` actually attached (verified with a real API call)
- [ ] Named profile configured, `AWS_PROFILE` exported
- [ ] Downloaded access-keys CSV deleted
- [ ] Cost Explorer enabled
- [ ] $50 monthly budget alarm with 80% / 100% notifications
- [ ] Free tier terms checked for this region
- [ ] `aws sts get-caller-identity` returns an account
- [ ] `AWS_PROFILE` exported in `.bashrc` — unset, Terraform silently falls back to `[default]`
- [ ] `terraform apply` in `bootstrap/state` succeeds
- [ ] State migrated to S3 (`terraform state list` still shows resources)

---

## Next

[Phase 1 — Foundation](../01-mvp/phase-1-foundation.md)
