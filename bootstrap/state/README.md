# Step 0 — State backend

Creates the S3 bucket and DynamoDB lock table that every other Terraform config in this
repo stores its state in.

There is exactly one of these per AWS account. It is not per environment. Environments
are separated by the `key` prefix inside the bucket instead, which keeps locking,
versioning, encryption, and access control identical for all of them.

## Why this is separate

Terraform cannot bootstrap its own remote backend. The backend block is read before any
resource is created, so the thing it points at has to already exist. This config is the
part that breaks the cycle: it runs with local state, creates the bucket, and every
config after it uses remote state from the first apply onward.

## Run it

`backend.tf` is committed, so this directory already points at remote state — but on a
brand new account the bucket it names does not exist yet. The first run therefore starts
with `-backend=false`, which initializes with local state and no backend:

```bash
cd bootstrap/state
export AWS_PROFILE=myapp

# 1. Init with NO backend. This is the ONLY step that uses local state.
terraform init -backend=false

# 2. Apply. Creates the bucket, KMS key, and lock table.
terraform apply

# 3. Init again, this time with the backend. Terraform copies local state into the bucket.
terraform init -migrate-state

# 4. Confirm it migrated and that nothing drifted.
terraform state list
terraform plan            # "No changes"
```

Step 3 is where the bucket starts being used. Before it, state is on your laptop — which
means the plaintext secrets it holds are too. Delete the local files once migrated:

```bash
rm -f terraform.tfstate terraform.tfstate.backup terraform.tfstate.*.backup
```

They are gitignored, so they cannot be committed, but they still sit on disk in the clear.

### If the bucket name is taken

The default is `myapp-tfstate-<account-id>`, and account IDs are globally unique, so the
default should not collide. If you overrode it and hit `BucketAlreadyExists`, pick another:

```bash
terraform apply -var 'bucket_name=myapp-tfstate-042617239394-2'
```

> This is the failure that a fixed default produces. `myapp-tfstate` on its own is already
> owned by someone else, and S3 names are global — so the very first apply fails with
> `409 BucketAlreadyExists`. The account-ID suffix exists to make that impossible.

If you do override `bucket_name`, remember to update `backend.tf` to match: a backend block
cannot read variables, so the two are not linked.

## Verify

Set the name once — the bucket is account-specific:

```bash
B=$(terraform output -raw state_bucket_name)
echo "$B"
```

```bash
# Public access is actually blocked
aws s3api get-public-access-block --bucket "$B"

# Versioning is on — this is your recovery path
aws s3api get-bucket-versioning --bucket "$B"

# Encryption is KMS with a customer-managed key, not SSE-S3
aws s3api get-bucket-encryption --bucket "$B"

# Lock table exists
aws dynamodb describe-table --table-name myapp-tflock \
  --query 'Table.{Billing:BillingModeSummary.BillingMode,Status:TableStatus}'
```

Expected output, and what each proves:

| Command | Expected | Proves |
| --- | --- | --- |
| `get-public-access-block` | all four `true` | no accidental public exposure |
| `get-bucket-versioning` | `Enabled` | a bad apply is recoverable |
| `get-bucket-encryption` | `aws:kms` + a key ARN | encryption uses your CMK, so decrypts are attributable in CloudTrail |
| `describe-table` | `PAY_PER_REQUEST`, `ACTIVE` | locking works, no provisioned capacity to under-size |

Not covered by the above: an empty-region or wrong-region deploy. Confirm the region the
resources landed in:

```bash
aws s3api get-bucket-location --bucket "$B"
aws dynamodb describe-table --table-name myapp-tflock \
  --query 'Table.TableArn' --output text
```

That second one matters. A table created before the region default was settled landed in
the wrong region, and Terraform did not notice — it tracked the table by name, and the name
looked the same. Only the ARN reveals the region.

## What this does not protect against

The state file contains secrets in plaintext. Anyone who can `aws s3 cp` the object, or
read it via the KMS key, can read every secret the state holds — including ones you did
not think of as secrets. Confirm what you are exposing:

```bash
terraform state pull | grep -i password
```

The protections here are versioning (recoverable), KMS encryption (at rest), a
TLS-only bucket policy (in transit), public access blocked (not exposed), and
IAM-scoped reads (only principals with `s3:GetObject` on this bucket). What it does not
do is hide secrets from someone who legitimately has read access, which is why Phase 5
should not put raw database passwords into Terraform-managed resources at all.

## Wiring an environment to this backend

Take the `backend_config` output:

```bash
terraform output backend_config
```

Then paste it into `infra/envs/dev/backend.tf`, replacing `REPLACE_ME` with the
environment name — the key must differ per environment or they will share state:

```hcl
backend "s3" {
  bucket         = "myapp-tfstate-042617239394"
  key            = "dev/terraform.tfstate"
  region         = "eu-central-1"
  dynamodb_table = "myapp-tflock"
  encrypt        = true
  kms_key_id     = "arn:aws:kms:eu-central-1:042617239394:key/9c2a2d41-5b14-4968-8862-339509379ec8"
}
```

Then `terraform init` in that environment. Terraform prompts to copy the existing local
state if there is any; there should not be, since this is a fresh environment. Answer
`no` if it asks.

## Cost

| Item | Monthly |
| --- | --- |
| S3 bucket + versioned state | ~$0.50 |
| DynamoDB `PAY_PER_REQUEST` | ~$0.00 idle |
| KMS key | ~$1.00 |
| **Total** | **~$1.50/mo** |

## Next

[Phase 1 — Foundation](../../01-mvp/phase-1-foundation.md) — VPC, EKS, ECR, and the OIDC
identity that the workflows in Phase 3 will use.
