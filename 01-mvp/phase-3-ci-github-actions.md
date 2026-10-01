# Phase 3 — GitHub Actions (CI)

**Goal:** three workflows that build, scan, and publish — and provably do not deploy.

**Depends on:** Phase 1 (ECR + OIDC roles). **Parallelizable with Phase 2.**

> **Start this phase alongside Phase 2.** `cd.yml` needs ECR (Phase 1) and a Dockerfile, not
> a working cluster. Testing CI against a scratch ECR repository while the Helm installs
> finish saves a day of wall-clock time.

---

## The split, and why it is the design

| Workflow | Trigger | AWS access | Purpose |
| --- | --- | --- | --- |
| `ci.yml` | `pull_request` | **none** | Validate, build, scan |
| `cd.yml` | `push` to `main` | OIDC → ECR push only | Publish the image |
| `infra.yml` | PR (plan) / dispatch (apply) | read-only / write, separate roles | Terraform plan and apply |

The split is not tidiness. Three properties fall out of it:

1. **A pull request cannot touch AWS.** `ci.yml` has no `configure-aws-credentials` step
   and no role, so there is nothing to escalate to — including from a fork.
2. **The blast radius of each role is small.** `ci-ecr-push` cannot run Terraform. `infra-apply`
   cannot push images. Neither can do both.
3. **Only `main` can publish.** The `sub` condition scopes `cd.yml` to `refs/heads/main`.

---

## `ci.yml` — no AWS access at all

```yaml
name: ci
on:
  pull_request:
    branches: [main]

# Declare permissions explicitly. The default GITHUB_TOKEN scope is broad.
permissions:
  contents: read

concurrency:
  group: ci-${{ github.head_ref || github.ref }}
  cancel-in-progress: true

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: '22'
          cache: npm
      - run: npm ci
      - run: npm test --if-present
      - run: npm audit --audit-level=high

  build-and-scan:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-buildx-action@v3
      # Build only. Never push — this workflow has no ECR credentials, by design.
      - uses: docker/build-push-action@v6
        with:
          context: ./nodeapp
          push: false
          tags: nodeapp:${{ github.sha }}
          cache-from: type=gha
          cache-to: type=gha,mode=max

      - uses: aquasecurity/trivy-action@0.28.0
        with:
          image-ref: nodeapp:${{ github.sha }}
          severity: 'HIGH,CRITICAL'
          exit-code: '1'        # fail the build, do not merely warn
```

There is no `configure-aws-credentials` step. That absence **is** the security control.
Verify it rather than trusting the file:

```bash
# open a PR from a fork, let ci.yml run, confirm:
#   - no OIDC token was requested
#   - the workflow succeeded
#   - nothing appeared in CloudTrail
```

`exit-code: '1'` is deliberate. A scanner that warns is a scanner nobody reads. If a real
HIGH finding blocks you mid-build, triage it once and add an ignore with a reason rather
than dropping the threshold to CRITICAL.

---

## `cd.yml` — OIDC → ECR, and nothing else

```yaml
name: cd
on:
  push:
    branches: [main]

permissions:
  contents: read
  id-token: write        # required for OIDC. Scoped to this workflow only.
  packages: write

concurrency:
  group: cd-${{ github.ref }}
  cancel-in-progress: true   # a superseded push must not race a newer one

jobs:
  publish:
    runs-on: ubuntu-latest
    environment: production   # gates on required reviewers if your plan allows
    steps:
      - uses: actions/checkout@v4

      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::ACCT:role/myapp-ci-ecr-push
          aws-region: eu-west-1
          # no aws-access-key-id. none. ever.

      - uses: aws-actions/amazon-ecr-login@v2

      - uses: docker/setup-buildx-action@v3

      - id: meta
        uses: docker/metadata-action@v5
        with:
          images: ACCT.dkr.ecr.eu-west-1.amazonaws.com/myapp
          tags: |
            type=sha,format=long
            type=semver,pattern={{version}}
            type=semver,pattern={{major}}.{{minor}}

      - uses: docker/build-push-action@v6
        with:
          context: ./nodeapp
          push: true
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
          cache-from: type=gha
          cache-to: type=gha,mode=max

      - uses: actions/upload-artifact@v4
        with:
          name: image-digest
          path: /tmp/digest.txt      # the SHA to deploy, for traceability
```

### Two hard constraints on this file

**It writes only to ECR.** It does not touch `values.yaml`, does not run `kubectl`, does not
call Terraform, does not call Argo CD. CI ends at the registry. The moment a workflow
deploys, you have a push deployment wearing a GitOps hat — and Argo CD will fight it,
because Argo CD reconciles the cluster back to Git and your `kubectl` change is drift it
immediately reverts.

**`permissions` is declared explicitly.** The default `GITHUB_TOKEN` scope includes write
access to contents and packages. A workflow that only pushes an image should not hold it.

### Why `environment: production`

Two reasons, and they compound. It lets you attach required reviewers (a code-level
approval gate with an audit trail), and — critically — **it changes the `sub` claim** to
`repo:ORG/REPO:environment:production`. If your trust policy is written against that form,
a workflow that forgets the `environment:` line simply cannot assume the role. The
environment becomes part of your authorization model rather than a UI convenience.

### Tagging strategy

| Tag | Purpose |
| --- | --- |
| `<full-sha>` | Immutable, traceable to a commit |
| `v1.4.2` | What Image Updater tracks with `semver` |
| `v1.4` | Convenience alias |

Image Updater's `allowTags` regex will be scoped to the semver form, so SHA tags never
trigger it. This is what prevents the commit-on-every-build churn described in Phase 4.

---

## `infra.yml` — plan on PR, apply gated

```yaml
name: infra
on:
  pull_request:
    paths: ['infra/**', '.github/workflows/infra.yml']
  workflow_dispatch:

jobs:
  plan:
    if: github.event_name == 'pull_request'
    runs-on: ubuntu-latest
    permissions:
      contents: read
      id-token: write
      pull-requests: write
    steps:
      - uses: actions/checkout@v4
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::ACCT:role/myapp-infra-plan   # READ-ONLY
          aws-region: eu-west-1

      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_wrapper: false   # you want the exit code, not "apply anyway?"

      - uses: actions/cache@v4
        with:
          path: ~/.terraform.d
          key: tfproviders-{{ runner.os }}-${{ hashFiles('infra/**/*.tf') }}
          restore-keys: tfproviders-

      - run: terraform init
        working-directory: infra/envs/dev
      - run: terraform fmt -check -recursive
      - run: terraform validate
      - run: terraform plan -no-color -out=tfplan
      - run: terraform show -no-color tfplan > plan.txt

      - uses: actions/upload-artifact@v4
        with:
          name: tfplan
          path: infra/envs/dev/tfplan

      # Post the plan as a PR comment — reviewers should not need to clone anything
      - uses: actions/github-script@v7
        with:
          script: |
            const fs = require('fs');
            const body = fs.readFileSync('plan.txt', 'utf8');
            await github.rest.issues.createComment({
              issue_number: context.issue.number,
              owner: context.repo.owner,
              repo: context.repo.repo,
              body: '## Terraform plan
```diff
' + body + '
```'
            });

  apply:
    if: github.event_name == 'workflow_dispatch'
    runs-on: ubuntu-latest
    environment: production
    permissions:
      contents: read
      id-token: write
    steps:
      - uses: actions/checkout@v4
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::ACCT:role/myapp-infra-apply   # SEPARATE write role
          aws-region: eu-west-1
      - uses: hashicorp/setup-terraform@v3
        with: { terraform_wrapper: false }
      - uses: actions/cache@v4
        with:
          path: ~/.terraform.d
          key: tfproviders-{{ runner.os }}-${{ hashFiles('infra/**/*.tf') }}
          restore-keys: tfproviders-
      - run: terraform init
        working-directory: infra/envs/dev
      - run: terraform plan -detailed-exitcode -out=tfplan
        # 0 = no changes (exit 1, harmless), 2 = changes (continue). Other codes are errors.
        continue-on-error: true
      - run: terraform apply -auto-approve tfplan
      - run: terraform show -no-color tfplan > applied.txt
      - uses: actions/upload-artifact@v4
        with: { name: apply-log, path: infra/envs/dev/applied.txt }
```

### Two roles, not one

| Role | Scope | Runs on |
| --- | --- | --- |
| `infra-plan` | read: `*Describe*`, `ecr:GetAuthorizationToken`, state read | Every PR |
| `infra-apply` | Terraform's full write surface | Manual dispatch, protected environment |

Collapsing them means any merged PR can write infrastructure. Keeping them separate means
the PR path — the path with the most contributors and the least scrutiny — can only read.

### Three implementation details that matter

**`terraform_wrapper: false`.** The wrapper's default behaviour is to exit 0 and print
"Error: running 'terraform plan'... here you go" — which means a *failing* plan looks like a
passing one. Turning it off means you get real exit codes.

**`-detailed-exitcode`.** Exit 2 means "changes present," which is not an error. Handling
it explicitly is what makes an empty plan distinguishable from a crashed plan.

**Cache `~/.terraform.d`.** Provider plugins are hundreds of MB. Without the cache every run
downloads them, which is slow enough to make people skip validation steps. Note this is the
*plugin* cache; the backend cache lives in the S3 bucket.

---

## Supply chain: pin to SHAs

Every `uses:` above is written as `@v4` for readability. **Before merging, pin them all to
commit SHAs:**

```yaml
- uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683  # v4.2.2
- uses: aws-actions/configure-aws-credentials@e3dd6a429d7300a6a4c196c26e071d42e0343502  # v4.0.2
```

Then keep them updated:

```yaml
# .github/dependabot.yml
version: 2
updates:
  - package-ecosystem: github-actions
    directory: /
    schedule: { interval: weekly }
```

A tagged action can be re-pointed at new content. A commit SHA cannot. A workflow with
`id-token: write` and ECR push access is code that can run against your cloud account, and
treating it as untrusted input is the correct posture. Do the pinning before you finish this
phase, not as a cleanup.

---

## Supporting files

### `.github/workflows/` structure

```
.github/workflows/
├── ci.yml           # PR: validate, build, scan. No AWS.
├── cd.yml           # main: OIDC → ECR push. Nothing else.
└── infra.yml        # PR: plan. dispatch: apply.
```

### `.dockerignore`

```
node_modules
.git
.github
*.md
.env
```

Without this, `node_modules` goes into the build context, the image is enormous, and layer
caching barely works.

### The Dockerfile — already required, but check it

```dockerfile
FROM node:22-alpine AS deps
WORKDIR /app
COPY package*.json ./
RUN npm ci --omit=dev

FROM node:22-alpine AS runtime
WORKDIR /app
ENV NODE_ENV=production
COPY --from=deps /app/node_modules ./node_modules
COPY package*.json ./
COPY app.js ./
USER node                      # non-root. The default node image already has this user.
EXPOSE 3000
CMD ["node", "app.js"]
```

Multi-stage so dev dependencies and build tooling never reach the runtime layer. `USER node`
so a container escape does not start as root.

### Branch protection

Set on `main`: require `ci.yml` to pass, require one approving review, forbid force-push,
require linear history. This is what makes "CI gates the merge" a real control rather than a
convention — and it is free.

---

## Verify before moving on

```bash
# 1. A fork PR cannot reach AWS
#    open a PR from a fork -> ci.yml succeeds, no OIDC token requested,
#    nothing in CloudTrail

# 2. A feature branch cannot publish
#    push a commit to a feature branch -> cd.yml does not run at all,
#    and if you invoke it manually, assume-role fails

# 3. Two merges, two images, nothing else
#    push to main twice
aws ecr describe-images --repository-name myapp   --query 'imageDetails[*].{tag:imageTags[0],pushed:imagePushedAt}'
#    -> exactly 2 new images. No extra tags per build.

# 4. CI never deploys
kubectl get deploy -A | grep -v -E "argo|external|ingress|lb-controller"
#    -> nothing app-related. Nothing redeployed.

# 5. Scanning actually blocks
#    commit a package.json with a known-vulnerable dependency -> build FAILS

# 6. Terraform plan is visible to reviewers
#    open a PR touching infra/ -> the plan is posted as a comment

# 7. Every action is SHA-pinned
grep -rE "uses: [^@]+@v[0-9]" .github/workflows/ && echo "FOUND FLOATING TAGS"
#    -> no output
```

Check 7 as written exits non-zero when it finds floating tags — which is what you want, so
run it deliberately rather than as part of a `&&` chain in CI where you will misread the
result.

---

## Exit criteria

- [ ] `ci.yml` completes with **no** AWS credentials in scope
- [ ] A fork PR cannot reach AWS — verified, not assumed
- [ ] A feature branch cannot assume `ci-ecr-push`
- [ ] Two consecutive merges produced exactly two new ECR tags
- [ ] No app-related workload appeared in the cluster
- [ ] A HIGH severity Trivy finding fails the build
- [ ] `infra-plan` and `infra-apply` are separate roles with different scopes
- [ ] `terraform plan` is posted as a PR comment
- [ ] All `uses:` pinned to commit SHAs — zero floating tags
- [ ] Branch protection enabled on `main`
- [ ] `.dockerignore` present, image size sane

---

## Common failures

| Symptom | Cause | Fix |
| --- | --- | --- |
| `configure-aws-credentials` fails | Trust policy `sub` does not match context | Decode the token; `environment: production` and `ref:` produce different `sub` values |
| Same failure, "not authorized" | Role ARN wrong, or the role's trust policy has a typo in the `aud` condition | `aud` must be exactly `sts.amazonaws.com` |
| OIDC provider thumbprint error | Stale thumbprint list | Drop it — AWS is root-CA based now — or refresh from the GitHub API |
| `npm audit` fails on transitive deps | Common, especially dev-only | `--omit=dev` in the audit, or an explicit override. Do not blanket-raise the threshold |
| Build takes 8 minutes | No layer cache | Add `cache-from`/`cache-to: type=gha` and a proper `.dockerignore` |
| Terraform plan step succeeds despite errors | `terraform_wrapper` defaulting to true | Set `terraform_wrapper: false` |
| Every run downloads providers | `~/.terraform.d` not cached | Add `actions/cache` on that path |
| Two images pushed per commit | `metadata-action` tags misconfigured | Expect one tag per line in the `tags:` block, not per build |
| Workflow runs on a fork PR and hangs | `pull_request_target` misuse | Use plain `pull_request`; never give fork code a privileged context |

---

## Cost contribution

GitHub-hosted Linux runners are free for public repos and included in the 2,000 min/month
allowance for private repos. This project sits well inside that — three workflows, one
repo.

**The cost is what you *don't* pay:** no EC2 instance for a Jenkins controller, no EBS
volume for `JENKINS_HOME`, no capacity reserved for a 4 vCPU / 8 GB controller that runs
mostly idle. Level 1 total unchanged at **~$208/mo**.
