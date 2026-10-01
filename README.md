# GitOps Pipeline on AWS — Implementation Levels

Working implementation of the architecture described in
[`../architecture-review-github-actions.md`](../architecture-review-github-actions.md).

**Stack:** Terraform · Amazon EKS · GitHub Actions (CI) · Argo CD + Argo CD Image Updater (CD)
· External Secrets Operator · Helm · Node.js + MySQL + Redis

---

## The three levels

Each folder is a self-contained stage of the build. You do not skip ahead — each level
depends on the one before it.

| Level | Folder | What it is | Cost/mo | Time to build |
| --- | --- | --- | --- | --- |
| **MVP** | [`01-mvp/`](01-mvp/) | Minimum that proves the CI/CD loop end to end | ~$110 | 1–2 days |
| **Production** | [`02-production/`](02-production/) | Everything the design calls for, hardened | ~$290 | 3–5 days |
| **Scale** | [`03-scale/`](03-scale/) | Deliberately deferred. Each item has a trigger | TBD | As triggered |

Read each level's README before starting it. They contain the scope, the reasoning, the
exit criteria, and the specific failure modes to expect at that stage.

---

## How the levels map to the roadmap

The architecture review lays out 8 phases. They group cleanly into the 3 levels:

| Roadmap phase | Lands in |
| --- | --- |
| 1 — Foundation (Terraform + OIDC bootstrap) | MVP |
| 2 — Cluster platform components (Helm installs) | MVP |
| 3 — CI (GitHub Actions) | MVP |
| 4 — CD / GitOps | Production |
| 5 — Application + data layer | Production |
| 6 — Ingress + TLS | Production |
| 7 — Security hardening | Production |
| 8 — Observability + reliability | Production |
| Scale triggers | Scale |

Phase 3 is parallelizable with phase 2: CI can be built and tested against a scratch ECR
repository while the Helm installs are still running. Start both, save wall-clock time.

---

## The architecture, end to end

```
Developer ──PR──▶ GitHub ──▶ Actions (no AWS creds) ──▶ validated + scanned image
                        │
                        └──merge to main──▶ Actions ──OIDC──▶ AWS STS ──▶ ECR
                                                                      │
ECR ◀──image discovery── Argo Image Updater ◀── writes values.yaml ───┘
                    │                                    │
                    └── Git commit ──▶ Argo CD ──sync──▶ EKS

Secrets Manager ──Pod Identity──▶ External Secrets Operator ──▶ K8s Secret ──▶ App
App ──▶ RDS MySQL / ElastiCache Redis  (private subnets, SG-scoped)
User ──▶ DNS ──▶ NLB + ACM TLS ──▶ NGINX Ingress ──▶ App
```

Three things to hold onto while you build:

1. **CI ends at the registry.** No workflow runs `kubectl apply`. Actions pushes an image
   and stops. Argo CD deploys. The moment a workflow deploys, you have a push deployment
   wearing a GitOps hat.
2. **One writer per file.** Image Updater is the *only* thing that writes `values.yaml`.
   Actions pushes to ECR and writes nothing to Git manifests. Two writers is how you get
   commit churn on every single build.
3. **Terraform owns the platform, Argo CD owns the workloads.** Never let them overlap on
   the same resource. That boundary is the whole design.

---

## Prerequisites

- AWS account with an existing IAM user/role able to create VPC, EKS, IAM, and S3 resources
- `terraform` >= 1.6, `helm` >= 3.12, `aws` CLI v2 configured
- `kubectl` configured against the cluster once it exists
- A **private** GitHub repo — this changes how the OIDC trust conditions behave
- A DNS name, or use `sslip.io` / `nip.io` for a throwaway environment

## Conventions used across all levels

- Terraform state lives in S3 with versioning + `block_public_access`, locked via DynamoDB
- One IAM role per identity. No shared roles, no `*:*`
- EKS authentication via Access Entries. Never `aws-auth`
- In-cluster AWS access via EKS Pod Identity. Never node IAM roles
- Images tagged with the Git SHA plus a semver alias. Never `latest`
- Helm for all Kubernetes manifests. `values.yaml` is the Image Updater write-back target
