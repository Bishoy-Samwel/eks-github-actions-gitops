# Step 0 explained — the Terraform state backend

Step 0 is the state backend: the S3 bucket, KMS key, and DynamoDB lock table that every
other Terraform configuration in this repo writes its state into. It is called "step 0"
because nothing else can be applied until it exists — not Phase 1, not the EKS cluster, not
a single environment.

This document explains *why* it exists and *what each resource is protecting against*. For
the commands to actually run it, see [`README.md`](README.md).

---

## 1. The problem: Terraform cannot bootstrap its own back end

Terraform keeps a state file — a JSON record of every resource it manages and every
attribute of those resources. By default that file lives next to your code on disk.

That is fine on a laptop for a toy, and wrong for everything else:

- **It is not shared.** If two people apply, they each have their own out-of-date copy and
  silently overwrite each other's infrastructure.
- **It is not durable.** Deleting the directory loses the mapping between code and real
  resources. Terraform can no longer tell what it owns, so it cannot update or destroy it.
- **It holds secrets in plaintext.** Database passwords, keys, anything an attribute
  contains. A local file in a git checkout is the worst place for that.

The fix is a *remote* back end: state stored in S3, with a lock table so two applies cannot
run at once. But that creates a circular problem:

> The backend block is the first thing Terraform reads. It tells Terraform where state
> lives. So the bucket the block points at has to exist **before** the config that uses the
> block can run — including the config that would create the bucket.

Terraform cannot write state to a bucket it has not created yet. Step 0 breaks the cycle by
being the one configuration that runs with **local** state, creates the bucket, and only
then migrates to it.

```
step 0 (local state)  ──creates──▶  S3 bucket + lock table
       │                                     ▲
       └──────── migrates its state ─────────┘
                                             ▲
phase 1+, dev, prod  ──── remote backend ────┘
```

Everything after step 0 starts on remote state from its very first apply.

---

## 2. Why the bucket is treated like a credential store

The state file is not scratch space. It contains, in plaintext:

- every attribute of every managed resource, including generated passwords and keys;
- the outputs of any config that produces a secret;
- enough detail to reconstruct your infrastructure.

So the bucket is locked down the way you would lock down a secrets store, not the way you
would a build artifact. Almost every resource in step 0 is one of those locks.

---

## 3. What step 0 creates, and why

### S3 bucket — where state lives

The container itself. Two properties matter:

- **`lifecycle { prevent_destroy = true }`.** Without it, a single `terraform destroy` — in
  any config that shares this backend — deletes the bucket and therefore the state for
  everything. Terraform is made to refuse instead of silently succeeding.
- **The name includes the account ID** (`myapp-tfstate-<account-id>`). S3 bucket names are
  global across all of AWS. A fixed name like `myapp-tfstate` is already owned by someone
  else, so the first apply fails with `409 BucketAlreadyExists`. Account IDs are globally
  unique, so appending one makes the default impossible to collide with.

### Versioning — the recovery path

With versioning enabled, every overwrite of the state file keeps the previous version. That
turns the most common serious incident — "a bad apply corrupted state" — into a recoverable
one:

```bash
aws s3api list-object-versions --bucket "$B" --prefix bootstrap/terraform.tfstate
```

Without versioning, a corrupted state overwrite is simply gone. With it, recovery is a
copy of an older version back over the current one. This is the single most valuable
setting here, and the lifecycle rule below is deliberately set to keep old versions for a
while before expiring them.

### KMS key and alias — encryption you can audit

State is encrypted at rest. The choice is *which* key:

| Option | Who controls it | Audit trail | Rotation |
| --- | --- | --- | --- |
| SSE-S3 (`AES256`) | AWS-managed | not visible in CloudTrail | automatic, no policy |
| SSE-KMS, AWS-managed key | AWS | limited | automatic, no policy |
| SSE-KMS, **customer-managed key** | you | full CloudTrail `Decrypt`/`GenerateDataKey` per call | `enable_key_rotation` you control |

Step 0 uses a customer-managed key. It costs about a dollar a month, and in exchange you can
answer "who decrypted the state file, and when" — which you cannot do with SSE-S3. The
bucket key (`bucket_key_enabled = true`) keeps the per-object KMS call cost down.

`deletion_window_in_days = 30` gives a month to cancel an accidental key deletion. Delete
the key and the state it encrypted becomes unreadable forever.

### Ownership controls — `BucketOwnerEnforced`

S3's default ownership mode lets other accounts claim ownership of objects they write. For a
state bucket there should be no ambiguity: the account that owns the bucket owns every
object in it. `BucketOwnerEnforced` also disables ACLs, which removes a whole class of
"who can read this" surprises.

### Public access block — all four flags

```
block_public_acls, ignore_public_acls, block_public_policy, restrict_public_buckets
```

Each closes a different door to accidental public exposure. State must never be reachable
without credentials, so all four are on.

### Bucket policy — deny non-TLS

The public access block stops public exposure; this rule stops plaintext exposure. It denies
`s3:*` for any request where `aws:SecureTransport` is `false`. A misconfigured legacy client
cannot put your state on the wire unencrypted.

### Lifecycle rules — stop paying for old versions

Two rules keep the bucket from growing forever:

- **Expire noncurrent versions** after a retention window (default 90 days). Versioning is
  the recovery path, but it is not free — old versions accumulate. The window is set
  comfortably longer than the number of applies you might need to walk back.
- **Abort incomplete multipart uploads** after 7 days. An interrupted upload leaves
  billable fragments that otherwise sit there forever.

### DynamoDB table — locking

Terraform only locks state if the backend names a lock table. Without one, two applies can
run at the same time: each reads state, each writes it back, and the second write does not
know about the first. The result is state that references resources that were renamed or
never created — the kind of breakage that is expensive to untangle.

The table is deliberately minimal:

- one attribute, `LockID` (string) — that is all the backend protocol uses;
- `billing_mode = "PAY_PER_REQUEST"` — no provisioned capacity to guess at, no cost when
  idle. An under-provisioned lock table throttles lock acquisition, and a failed lock
  acquisition fails your deploy.

It stores only lock IDs, so it does not need the same encryption treatment as the state
bucket.

---

## 4. How the bootstrap itself works

Because the bucket does not exist on a brand new account, the first run cannot use the
backend:

```bash
export AWS_PROFILE=myapp
cd bootstrap/state

terraform init -backend=false    # no backend yet; state stays local
terraform apply                  # creates bucket, key, and lock table
terraform init -migrate-state    # now attach the backend; copy local state into S3
terraform state list             # prove it moved
terraform plan                   # "No changes"
```

- **`-backend=false`** initializes providers without configuring remote state. This is the
  only step that uses local state.
- **`-migrate-state`** on the second `init` copies the local state file into S3 and switches
  to it. After this, the bucket is authoritative.
- **Delete the leftover local files** (`terraform.tfstate*`). They are gitignored, but they
  still contain plaintext secrets on disk.

Once the bucket exists, every later `init` is just `terraform init`.

---

## 5. How the rest of the repo uses it

Other configs point at this backend with a literal block — a backend cannot read variables
or data sources, so the values are written out:

```hcl
backend "s3" {
  bucket         = "myapp-tfstate-<account-id>"
  key            = "dev/terraform.tfstate"   # different per environment
  region         = "eu-central-1"
  dynamodb_table = "myapp-tflock"
  encrypt        = true
  kms_key_id     = "arn:aws:kms:eu-central-1:<account-id>:key/<id>"
}
```

`terraform output backend_config` prints this block already filled in. The **`key` must
differ per environment**; if two environments share a key they share state and will fight
over each other's resources.

---

## 6. What breaks without step 0

| If you skip… | What goes wrong |
| --- | --- |
| remote state entirely | state is unshared, easy to lose, and lives in plaintext in your checkout |
| the lock table | concurrent applies silently corrupt state |
| versioning | a bad apply is unrecoverable |
| `prevent_destroy` | one `destroy` deletes the state for everything |
| the customer-managed KMS key | no CloudTrail trail of who read your secrets |
| the account-ID suffix | first apply fails with `BucketAlreadyExists` |
| a per-environment `key` | two environments overwrite each other's state |

---

## 7. Cost

| Item | Monthly |
| --- | --- |
| S3 bucket + versioned state | ~$0.50 |
| DynamoDB `PAY_PER_REQUEST` | ~$0.00 idle |
| KMS key | ~$1.00 |
| **Total** | **~$1.50/mo** |

Cheap relative to what it prevents. The KMS key is the only fixed cost; it is billed per
month whether or not anything reads the state.

---

## 8. Verifying it is actually in effect

The README lists the full set. The point of running them is that a setting can be present in
`.tf` and still not be true in AWS — check the live API, not the file:

```bash
B=$(terraform output -raw state_bucket_name)

aws s3api get-public-access-block --bucket "$B"   # all four true
aws s3api get-bucket-versioning   --bucket "$B"   # Enabled
aws s3api get-bucket-encryption   --bucket "$B"   # aws:kms + customer key ARN
aws dynamodb describe-table --table-name myapp-tflock \
  --query 'Table.{Billing:BillingModeSummary.BillingMode,Status:TableStatus}'
```

---

## 9. The one thing it does not fix

The bucket protects state **in transit, at rest, and from the wrong people**. It does not
stop someone who legitimately has read access, and it does not make state non-sensitive.
Anyone with `s3:GetObject` plus `kms:Decrypt` reads every secret in it.

That is why the later phases should avoid putting raw credentials into Terraform-managed
resources at all — the real fix for secret handling is not to have secrets in state in the
first place.

## Next

[Phase 1 — Foundation](../../01-mvp/phase-1-foundation.md), which depends on this backend.
