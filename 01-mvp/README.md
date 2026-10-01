# Level 1 — MVP

**Goal:** prove the CI/CD loop end to end. A developer pushes code, and the running
application changes with no human touching the cluster.

**Cost:** ~$208/month · **Build time:** 1–2 days

---

## What this level is

Not a production system. A working proof that every moving part connects:

- Terraform creates a VPC and an EKS cluster, with no manual step
- GitHub Actions builds and pushes an image using OIDC, no stored credentials
- Argo CD syncs the app from Git
- Image Updater notices the new image and triggers a deploy on its own

If this loop works, everything in Level 2 is hardening work rather than new architecture.

## What this level deliberately leaves out

Single-AZ-ish footprint, in-pod MySQL and Redis with no persistence, no HTTPS, no
observability, no drift detection, no hardening. Each of those is a real gap — the point
is that you are measuring the loop first and hardening second, not that they are optional.

---

## Phases

Each phase has its own file, with build order, verification commands, exit criteria, and a
failures table.

| # | Phase | File | Cost impact |
| --- | --- | --- | --- |
| 1 | Foundation | [phase-1-foundation.md](phase-1-foundation.md) | ~$208/mo (the whole level) |
| 2 | Cluster platform components | [phase-2-platform-components.md](phase-2-platform-components.md) | $0 |
| 3 | CI — GitHub Actions | [phase-3-ci-github-actions.md](phase-3-ci-github-actions.md) | $0 (free runner minutes) |

**Sequencing:** Phase 1 blocks both. Phase 2 and Phase 3 are independent of each other and
can run in parallel — Phase 3 needs only ECR and the OIDC roles from Phase 1, so CI can be
tested against a scratch repository while the Helm installs finish.

### Phase 1 — Foundation
Terraform + the GitHub OIDC identity. Nothing else can happen until this exists.
State backend, VPC, EKS cluster, ECR, Secrets Manager, Pod Identity agent, and the four
IAM roles. → [read](phase-1-foundation.md)

### Phase 2 — Cluster platform components
Argo CD, Image Updater, External Secrets, ingress — installed by Terraform's Helm provider.
The bootstrap boundary: Terraform owns the platform, Argo CD owns the workloads.
→ [read](phase-2-platform-components.md)

### Phase 3 — CI — GitHub Actions
`ci.yml` (PR, no AWS), `cd.yml` (main, OIDC → ECR only), `infra.yml` (plan on PR, apply
gated). CI ends at the registry. → [read](phase-3-ci-github-actions.md)

---

## Verify before moving on

Do all five. Each one catches a different class of mistake.

```bash
# 1. no manual step was needed
kubectl get nodes -o wide            # all Ready, all in PRIVATE subnets

# 2. state is clean and safe
terraform plan                          # "No changes"
aws s3api get-bucket-versioning         # Enabled
terraform state pull | grep -i password  # see what plaintext you just exposed to S3

# 3. the OIDC boundary actually holds
#    -> succeeds on main, fails on a feature branch and on a fork PR

# 4. CI never deploys
kubectl get deploy -n argocd           # only platform components, nothing app-related

# 5. drift check is honest
kubectl -n app delete pod <app-pod>    # nothing redeploys it — Argo CD does not manage it yet
```

Per-phase checks are in each phase file; run them as you finish that phase rather than
batching all of them at the end.

---

## Exit criteria

Level 2 starts only when all of these are true:

- [ ] `terraform apply` created the cluster with no manual bootstrap step
- [ ] Second `terraform plan` reports no changes
- [ ] All nodes `Ready`, all in private subnets
- [ ] Cluster authentication mode is `API`, not `CONFIG_MAP`
- [ ] A feature-branch workflow **cannot** assume the CI role — verified, not assumed
- [ ] A PR workflow completes with **no** AWS credentials in scope
- [ ] Two consecutive merges produced exactly two new ECR tags
- [ ] A HIGH severity Trivy finding fails the build
- [ ] All actions pinned to commit SHAs
- [ ] `terraform plan` is posted as a PR comment
- [ ] Argo CD installed and syncing a `hello` Deployment from Git
- [ ] Deleting that pod → Argo CD recreates it (self-heal proven)

---

## Common failures at this stage

| Symptom | Cause | Fix |
| --- | --- | --- |
| Workflow fails at `configure-aws-credentials` | Trust policy `sub` does not match the actual context | Print `sub` from the OIDC token; it differs for `environment:` vs `ref:`. Match exactly |
| Workflow hangs on `kubectl` | EKS endpoint is private-only; runner is outside the VPC | Set `endpoint_private_access = true` **and** keep `endpoint_public_access = true` with a CIDR allowlist |
| Argo CD cannot reach Git | Repo is private; no credentials configured | Add a `repository` Secret in the `argocd` namespace. A deploy key is fine for MVP |
| Image Updater writes nothing | Annotation-based config on a v1.x CRD release | v1.0 moved config into `ImageUpdater` CRs. Legacy `image-list` annotations are ignored |
| First sync fails: missing secret | No ordering between ESO and the app | Argo CD sync waves — see Level 2 |
| Node `NotReady` | Missing VPC CNI subnet permissions or IAM CNI policy | Attach `AmazonEKS_CNI_Policy` to the node role |

Phase-specific symptoms are in each phase file's failures table.

---

## Cost at this level

| Item | Monthly |
| --- | --- |
| EKS control plane | $73 |
| 3 × `t3.medium` | ~$100 |
| 1 NAT gateway | ~$33 |
| ECR + S3 + Secrets Manager | ~$2 |
| **Total** | **~$208** |

Higher than the $110 headline because the MVP uses `t3.medium` node groups rather than
right-sizing to `t3.small` later. Expect to trim this once you can read Container Insights.
