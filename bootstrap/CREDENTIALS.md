# AWS credentials on this machine

How the `myapp` profile gets set up, and why it exists.

The script is [`scripts/setup-aws-profile.sh`](scripts/setup-aws-profile.sh).

---

## The problem it solves

AWS shows an access key pair exactly once, then offers it as a CSV download. The obvious
next step — pasting those two values into `aws configure` — puts the secret into your
terminal scrollback and your shell history, where it stays until you clear both.

The script reads the CSV directly, writes the profile, and prints nothing sensitive. The
secret never appears in your terminal, in a log file, or in this repo.

---

## Usage

```bash
./bootstrap/scripts/setup-aws-profile.sh \
  --csv ~/Downloads/accessKeys.csv \
  --profile myapp \
  --region eu-central-1
```

| Flag | Default | Notes |
| --- | --- | --- |
| `--csv PATH` | required | The downloaded access-keys CSV |
| `--profile NAME` | `myapp` | Profile name to write |
| `--region REGION` | `eu-central-1` | Region for the profile |
| `--force` | off | Required to overwrite an existing profile |

Exit codes: `0` ok · `1` usage · `2` file problem · `3` write failed · `4` verify failed.

---

## What it does

1. Confirms the CSV exists
2. Refuses to overwrite an existing profile without `--force` — clobbering `default` by
   accident breaks whatever else on this machine was using it
3. Tightens the CSV to mode `600` if it is readable by group or other
4. Parses both values, handling the UTF-8 BOM Excel adds to the first column name
5. Validates shape: access key is `AKIA` + 16 chars, secret is exactly 40 chars
6. Writes to `~/.aws/credentials` (keys) and `~/.aws/config` (region)
7. Verifies by calling STS and printing the resolved ARN
8. Tells you to delete the CSV

Step 5 exists because a truncated or mis-pasted key fails at `terraform apply` with
`InvalidClientTokenId`, which is a much worse place to discover it than a clear message.

---

## Which file gets what

The profile name goes in brackets; the two files split by value type.

| Value | File | Block |
| --- | --- | --- |
| `aws_access_key_id` | `~/.aws/credentials` | `[myapp]` |
| `aws_secret_access_key` | `~/.aws/credentials` | `[myapp]` |
| `region` | `~/.aws/config` | `[profile myapp]` |

Both files are already mode `600`. After setup they look like this — `[default]` is left
untouched:

```ini
# ~/.aws/credentials
[default]
aws_access_key_id     = AKIA...
aws_secret_access_key = ...

[myapp]
aws_access_key_id     = AKIA...
aws_secret_access_key = ...
```

```ini
# ~/.aws/config
[default]
region = eu-central-1
output = json

[profile myapp]
region = eu-central-1
```

Two blocks, same name, merged at runtime. `aws configure` carries over `output = json` from
`[default]` when you do not set it explicitly.

---

## Verifying

```bash
aws configure list --profile myapp      # region + masked keys
aws sts get-caller-identity --profile myapp
```

The second is the check that matters. It prints:

```json
{
  "UserId": "AIDA...",
  "Account": "042617239394",
  "Arn": "arn:aws:iam::042617239394:user/admin"
}
```

Until that returns, every `terraform` command fails with `InvalidClientTokenId`. Common
cause: a stray leading or trailing space from a copy-paste. The script's validation catches
this; a manual paste does not.

---

## Then delete the CSV

```bash
rm ~/code-sapce/AWS/admin_accessKeys.csv
```

A plaintext secret sitting in a downloads folder is the most common way these leak. It was
read once by the script and is no longer needed.

---

## Required permissions

The user needs policies attached, or `terraform apply` fails at the first resource with
`AccessDenied`. In the console, signed in as root:

1. IAM → **Users** → click the user
2. **Permissions** tab → **Attach policies**
3. Attach **`AdministratorAccess`**

Verify with a real call rather than trusting the console:

```bash
aws iam list-attached-user-policies --profile myapp --user-name admin
```

If that returns `AccessDenied`, nothing is attached. Checking whether a specific action is
allowed:

```bash
aws s3api create-bucket --profile myapp \
  --bucket probe-permissions-test-042617239394 --region us-east-1
```

`AccessDenied` means no policy allows it. Success means it actually created a bucket —
delete it if you run this for real:

```bash
aws s3api delete-bucket --profile myapp \
  --bucket probe-permissions-test-042617239394 --region us-east-1
```

> Caution: `aws iam simulate-principal-policy` looks like the right tool here but will
> reject a policy-source ARN like `arn:aws:iam::aws:policy/AdministratorAccess`. Managed
> policy ARNs resolve to a version-specific ARN (`.../AdministratorAccess/<version-id>`) in
> that API. Use a direct API call against a real action instead.

---

## Using the profile

```bash
export AWS_PROFILE=myapp
```

One env var per shell, and it is the step people forget. Both the `aws` CLI and Terraform's
AWS provider check it and load the matching profile. Without it both fall back to
`[default]`, whose keys STS rejects — which surfaces as a confusing failure in `terraform`
rather than an obvious one in `aws`.

To make it stick:

```bash
echo 'export AWS_PROFILE=myapp' >> ~/.bashrc
```

---

## Why not `aws login` instead

Newer AWS CLI versions (>= 2.32.0) support `aws login`, which turns console credentials into
temporary CLI credentials — no access key at all, rotating automatically, valid up to 12
hours. AWS now recommends it, and it is the better long-term answer.

It was not available here: this machine has `aws-cli/2.24.7`. Upgrade first, then:

```bash
aws login --profile myapp
```

This works only if the IAM user was created with **console access** and has the
`SignInLocalDevelopmentAccess` managed policy attached. If you created the user with
access keys only, the access-key path above is the one you need.

---

## Deleting and rotating

```bash
aws iam delete-access-key --profile myapp \
  --user-name admin --access-key-id AKIA...
```

Only delete after the replacement is verified. Keep exactly one active key — a second key
doubles the window in which a leaked credential is valid and makes it impossible to tell
which one leaked.

---

## Relationship to the rest of the design

This profile is the *wrong* mechanism, used deliberately because it is the simple one.

| | Local Terraform | CI (Phase 3) |
| --- | --- | --- |
| Identity | `admin` IAM user | `myapp-ci-ecr-push` IAM role |
| Credential | Long-lived access key | OIDC web token, minted per run |
| Scope | Full admin | ECR push only, one repo |
| Lifetime | Never expires | Per workflow run |

The OIDC module in [Phase 1](../01-mvp/phase-1-foundation.md) exists to remove the left
column from CI. Your laptop key is acceptable for a human driving Terraform interactively;
the same credential in a workflow would be the vulnerability, not the design.

---

## Related

- [New AWS account setup](README.md) — the ordered account-level sequence
- [State backend runbook](state/README.md) — what step 0 creates once credentials work
