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

```bash
cd bootstrap/state

# 1. First apply. Local state — this is the ONLY apply that uses local state.
terraform init
terraform apply

# 2. Migrate to the bucket. Terraform moves the local state file across on init.
terraform init -migrate-state

# 3. Confirm it actually migrated.
terraform state list
```

Step 2 is where the bucket starts being used. Before it, state is on your laptop.

### If the bucket name is taken

S3 bucket names are global, so `myapp-tfstate` may already exist in someone else's
account. Override it:

```bash
terraform apply -var 'bucket_name=myapp-tfstate-BISH'
```

Or set it in `terraform.tfvars` (gitignored) so you do not have to remember the flag.
If you do, pick a name that carries your identity — you will be typing it in backend
blocks across several environments.

## Verify

```bash
# Public access is actually blocked
aws s3api get-public-access-block --bucket myapp-tfstate

# Versioning is on — this is your recovery path
aws s3api get-bucket-versioning --bucket myapp-tfstate

# Encryption is KMS, not just SSE-S3
aws s3api get-bucket-encryption --bucket myapp-tfstate

# Lock table exists and is server-side encrypted
aws dynamodb describe-table --table-name myapp-tflock \
  --query 'Table.{Billing:BillingModeSummary.BillingMode,Encrypted:SSEDescription.Status}'

# The bucket refuses to be deleted
terraform destroy
# -> Error: Resource aws_s3_bucket.state has lifecycle.prevent_destroy set
```

Check the destroy attempt. It is the only way to confirm `prevent_destroy` is actually
in effect rather than merely present in the file.

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
  bucket         = "myapp-tfstate"
  key            = "dev/terraform.tfstate"
  region         = "eu-central-1"
  dynamodb_table = "myapp-tflock"
  encrypt        = true
  kms_key_id     = "arn:aws:kms:eu-central-1:ACCT:key/REPLACE_ME"
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
