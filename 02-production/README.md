# Level 2 — Production

**Goal:** the architecture the design actually describes. Everything in Level 1 hardened,
plus the four things Level 1 cannot safely skip: GitOps as a real deploy path, a managed
data layer, HTTPS, and observability.

**Cost:** ~$290/month · **Build time:** 3–5 days

---

## What changes from Level 1

| Area | MVP | Production |
| --- | --- | --- |
| Footprint | 2 AZs, 1 NAT | 3 AZs, 1 NAT **per AZ** |
| Node groups | 1 mixed | Split: system (tolerations) + workload (autoscaling) |
| Database | MySQL pod, ephemeral | **RDS MySQL Multi-AZ**, automated backups |
| Cache | Redis pod, ephemeral | **ElastiCache Redis** |
| Ingress | none (port-forward) | NLB + NGINX + **ACM TLS** |
| Secrets | two in Secrets Manager | every credential, rotated |
| Workflows | plan/apply | + CODEOWNERS, `gitleaks`, scheduled drift check |
| Observability | none | Container Insights, control plane logs, 3 alarms |
| Network policy | none | default-deny in app namespace |
| Backups | none | RDS automated + one restore actually performed |

---

## Phase 4 — CD / GitOps

This is where the MVP's biggest gap closes. In Level 1 nothing deploys the app; here Argo CD
does, and Image Updater is what triggers it.

### The Application

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: myapp
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/ORG/REPO.git
    targetRevision: main
    path: charts/myapp          # ← this path is what Image Updater writes back to
    helm:
      valueFiles: [values.yaml]
  destination:
    server: https://kubernetes.default.svc
    namespace: app
  syncPolicy:
    automated:
      prune: true
      selfHeal: true            # revert manual changes — this is what makes it converge
      allowEmpty: false
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
    retry:
      limit: 5
      backoff: { duration: 10s, factor: 2, maxDuration: 3m }
```

`selfHeal: true` is the difference between GitOps that applies and GitOps that converges.
Without it, a stray `kubectl edit` survives indefinitely.

### Sync waves — the fix for first-sync failures

Without ordering, the app's first sync references a Secret and a database that do not exist
yet. This is the single most common first-run failure.

```yaml
# ESO first
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "-2"      # CRDs and the operator itself
# Secrets Store + ExternalSecret: wave "-1"
# MySQL / Redis (or their ExternalSecret refs): wave "0"
# app Deployment: wave "1"                    # last
```

Waves are how you express "this must exist before that." Getting this wrong looks like a
random race that only fails sometimes.

### The ImageUpdater CR — v1.x syntax

```yaml
apiVersion: argocd-image-updater.argoproj.io/v1alpha1
kind: ImageUpdater
metadata:
  name: myapp-images
  namespace: argocd          # must match where the Applications live
spec:
  writeBackConfig:
    method: git
    gitConfig:
      repository: https://github.com/ORG/REPO.git
      branch: main
      writeBackTarget: helmvalues:./charts/myapp/values.yaml
  applicationRefs:
    - namePattern: "myapp"     # glob, or use labels
      images:
        - alias: myapp
          imageName: <acct>.dkr.ecr.eu-west-1.amazonaws.com/myapp
          commonUpdateSettings:
            updateStrategy: semver        # NOT "newest-build" — see below
            allowTags: "regexp:^v?[0-9]+\.[0-9]+\.[0-9]+$"
            ignoreTags: ["latest", "dev"]
```

Three things people get wrong here:

- **`updateStrategy: newest-build` with SHA tags is a churn machine.** It updates on every
  build. Use `semver` with an `allowTags` regex so only real version bumps trigger a commit.
- **`spec.namespace` is deprecated** in v1.x. The controller uses the CR's
  `metadata.namespace`. Having the two differ is a silent failure.
- **The Git credential must not be committed.** Reference it from Secrets Manager:
  `argocd.argoproj.io/secret-type: repository` plus a `repository` Secret in the `argocd`
  namespace. A PAT in the manifest is a finding in any review.

### The single-writer rule — enforce it

Two components can write the image tag. Only one may write `values.yaml`.

- Actions → pushes to ECR. Writes nothing to Git manifests.
- Image Updater → sole writer of `values.yaml`.

Without this you get a commit every build and a Git history that tells no story. Enforce
it with `CODEOWNERS` so a bad merge gets a second review:

```
charts/myapp/values.yaml  @your-org/gitops-maintainers
```

### Rollback

A Git revert. That is the entire strategy, and it is a real advantage of the model — but
only if you say it out loud, because it is not obvious. `kubectl rollout undo` is
unavailable: Argo CD reconciles the drift away.

```bash
git revert <merge-sha> && git push    # Argo CD picks it up and rolls back
```

**The caveat that matters:** rollback is only safe if migrations are backward-compatible.
Reverting code against a narrower schema is an outage. Use expand/contract so every
released schema accepts every previously-released image.

### Migrations as a PostSync hook

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: myapp-migrate-{{`{{ .Revision }}`}}
  annotations:
    argocd.argoproj.io/hook: PostSync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
spec:
  backoffLimit: 0          # do not retry a failed migration
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: migrate
          image: <acct>.dkr.ecr.eu-west-1.amazonaws.com/myapp:{{`{{ .Image.Version }}`}}
          command: ["npm", "run", "migrate"]
          envFrom:
            - secretRef: { name: myapp-secrets }   # projected by ESO
```

A Job, not a Deployment — migrations run once per release and must not be left running.
`PostSync` means the Argo CD sync waits for success, so a failed migration halts the rollout
instead of shipping broken code.

---

## Phase 5 — Application + data layer

### RDS MySQL over an in-pod database

The requirements contradict themselves here (§5 says pods, the evaluation table says RDS).
Either way, RDS is the better answer, and it is what makes "production-ready" true rather
than aspirational.

| | StatefulSet + gp3 PVC | RDS Multi-AZ |
| --- | --- | --- |
| HA | none | automatic failover |
| Backups | you build them | automated + PITR |
| AZ failure | PVC stuck `Terminating` | standby promoted |
| Ops | upgrades, disk growth, restore testing | AWS owns it |
| Cost | ~$0 + node cost | ~$40/mo Multi-AZ |

```hcl
resource "aws_db_instance" "main" {
  identifier     = "myapp-dev"
  engine         = "mysql"
  instance_class = "db.t4g.micro"
  allocated_storage = 20
  storage_type   = "gp3"
  storage_encrypted = true
  kms_key_id     = aws_kms_key.main.arn

  multi_az = true                    # this is the entire point
  backup_retention_period = 7
  deletion_protection = true         # set false for a throwaway env, deliberately

  username = "admin"
  manage_master_user_password = true # → Secrets Manager, never in state as plaintext
  skip_final_snapshot = false

  db_subnet_group_name   = aws_db_subnet_group.private.name
  vpc_security_group_ids = [aws_security_group.db.id]   # 3306 from app SG only
}
```

`manage_master_user_password = true` is a quiet upgrade over hand-rolling the password: AWS
generates it, stores it in Secrets Manager, and rotates it. It also keeps the credential
out of Terraform state.

Then point ESO at it:

```hcl
resource "aws_secretsmanager_secret" "db" {
  name = "prod/myapp/db"
  # rds-managed credentials already exist; you may only need a mirror Secret
}
```

The `ExternalSecret` becomes trivial, and External Secrets Operator is doing real work
rather than mirroring a value that was already in a Kubernetes Secret.

### The app Deployment — the details that prevent deploy-time 502s

```yaml
spec:
  replicas: 2
  strategy:
    type: RollingUpdate
    rollingUpdate: { maxUnavailable: 0, maxSurge: 1 }   # never drop below desired capacity
  template:
    spec:
      securityContext: { runAsNonRoot: true, fsGroup: 1001 }
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
      containers:
        - name: app
          image: <acct>.dkr.ecr.eu-west-1.amazonaws.com/myapp:v1.0.0
          imagePullPolicy: IfNotPresent
          ports: [{ containerPort: 3000 }]
          # THREE probes, three different jobs. Conflating them is the classic outage.
          startupProbe:                       # slow starters get more room, no liveness kill
            httpGet: { path: /, port: 3000 }
            failureThreshold: 30
            periodSeconds: 2
          livenessProbe:                      # "is the process wedged?" → restart
            httpGet: { path: /healthz, port: 3000 }
            periodSeconds: 10
          readinessProbe:                     # "can it serve?" → remove from Service
            httpGet: { path: /ready, port: 3000 }   # must check the database
            periodSeconds: 5
          resources:
            requests: { cpu: 200m, memory: 256Mi }
            limits:   { memory: 512Mi }      # no CPU limit — CPU throttling is worse
          envFrom:
            - secretRef: { name: myapp-secrets }     # from ESO
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: ["ALL"] }
```

Three things people miss:

1. **A readiness probe that does not check the database** means every deploy has a window
   where the pod is in the Service but the DB connection is not established. 502s, every
   time.
2. **Using `liveness` where you meant `readiness`** causes restart loops — the kubelet
   kills pods for being briefly unable to serve.
3. **No CPU limit is often correct.** Requests set scheduling, memory limit prevents
   node-level damage, but CPU limits cause throttling that looks like unexplained latency.

### HPA, PDB, NetworkPolicy

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
spec:
  minReplicas: 2
  maxReplicas: 4
  metrics:
    - type: Resource
      resource: { name: cpu, target: { type: Utilization, averageUtilization: 70 } }
```

CPU is a lagging proxy for a memory-bound Node.js app. Fine at this scale; revisit with
custom metrics if it ever mispredicts.

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
spec:
  minAvailable: 1
  selector: { matchLabels: { app: myapp } }
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: default-deny, namespace: app }
spec:
  podSelector: {}
  policyTypes: [Ingress]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: allow-app-from-ingress, namespace: app }
spec:
  podSelector: { matchLabels: { app: myapp } }
  policyTypes: [Ingress]
  ingress:
    - from: [{ namespaceSelector: { matchLabels: { name: ingress-nginx } } }]
      ports: [{ port: 3000 }]
    - from: [{ podSelector: { matchLabels: { app: myapp } } }]   # self, for health checks
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: allow-egress-dns, namespace: app }
spec:
  podSelector: { matchLabels: { app: myapp } }
  policyTypes: [Egress]
  egress:
    - to: [{ namespaceSelector: { matchLabels: { name: kube-system } } }]
      ports: [{ port: 53, protocol: UDP }, { port: 53, protocol: TCP }]
    - ports: [{ port: 3306 }, { port: 6379 }]   # sg only — this is NOT scoped, see note
```

> **Note on that last rule:** scoping Egress to specific pods requires the CIDRs of RDS and
> ElastiCache, which are stable per-AZ but awkward to write by hand. Security groups already
> restrict *who can connect to* the database, so a default-deny ingress plus a narrow egress
> DNS rule is usually sufficient. Do not leave egress fully open either.

Verify enforcement — VPC CNI historically needs the network policy agent, and a
NetworkPolicy that nothing enforces is worse than none because it looks like a control:

```bash
kubectl -n app run test --rm -it --image=busybox --restart=Never -- sh -c   'nc -zv <rds-endpoint> 3306'     # should FAIL from a pod without the right label
```

---

## Phase 6 — Ingress + TLS

### ACM over Let's Encrypt

| | cert-manager + LE | ACM |
| --- | --- | --- |
| Components | a controller you must operate | none |
| Renewal | controller + ACME protocol + rate limits | automatic |
| HTTP-01 | needs public DNS, reachable ingress, 5 dup certs/week | n/a |
| With an NLB | awkward — you would front the LB for the challenge anyway | native |

cert-manager is named in the requirements, so **document it as the understood alternative**
rather than running it as the primary path. If you do run it, use the **staging** endpoint
during development — LE's production rate limit will bite you during iteration, and it is a
confusing failure to debug.

### The chain

```hcl
resource "aws_lb" "main" {
  name               = "myapp-nlb"
  internal           = false
  load_balancer_type = "network"
  subnets            = var.public_subnet_ids
  security_groups    = [aws_security_group.nlb.id]
}

resource "aws_lb_target_group" "app" {
  name        = "myapp-tg"
  port        = 80
  protocol    = "HTTP"
  target_type = "ip"       # required: pods get VPC IPs under the VPC CNI
  vpc_id      = var.vpc_id

  health_check {
    path     = "/ready"     # readiness, not / — a liveness-only check passes a broken pod
    matcher  = "200"
    interval = 10
    timeout  = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
  deregistration_delay = 30   # let in-flight requests finish
}

resource "aws_acm_certificate" "main" {
  domain_name       = var.domain_name
  validation_method = "DNS"     # DNS-01: no inbound needed, works with private ingress
  lifecycle { create_before_destroy = true }
}

resource "aws_acm_certificate_validation" "main" {
  certificate_arn         = aws_acm_certificate.main.arn
  validation_record_fqdns = [aws_route53_record.cert_validation.fqdn]
}
```

Two subtleties: `target_type = "ip"` (not `instance`) because pods have VPC IPs under the
VPC CNI; and the NLB health check should hit `/ready` so a pod that cannot reach its
database is pulled out of rotation.

### Ingress

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: myapp
  namespace: app
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod   # only if you chose cert-manager
    alb.ingress.kubernetes.io/scheme: internal
spec:
  ingressClassName: nginx
  tls:
    - hosts: [app.example.com]
      secretName: myapp-tls
  rules:
    - host: app.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service: { name: myapp, port: { number: 80 } }
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: myapp-force-https
  namespace: app
  annotations:
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
spec:
  ingressClassName: nginx
  rules:
    - host: app.example.com
      http: { paths: [{ path: /, pathType: Prefix, backend: { service: { name: myapp, port: { number: 80 } } } }] }
```

---

## Phase 7 — Security hardening

Work through this as a checklist against a real threat model, not a list of controls to tick.

### IAM review

There are **four** identities. Each has its own role, and none of them overlap:

| Identity | Mechanism | Scope |
| --- | --- | --- |
| Actions `cd.yml` | OIDC, `sub` = `repo:ORG/REPO:ref:refs/heads/main` | ECR push only |
| Actions `infra.yml` | OIDC, separate role | Terraform apply, protected environment |
| ESO / Image Updater | EKS Pod Identity | Only their own secrets |
| Humans | IAM Identity Center | admin / view / edit access entries |

Confirm the node role cannot read Secrets Manager. That is the standard escalation path —
an unconstrained pod on a node inherits the node role.

```bash
aws accessanalyzer validate-policy --policy-document file://policies/ci-ecr-push.json
```

### Least privilege over convenience

- **DB SG**: 3306 from the app SG only. Not `0.0.0.0/0`. Not from the node SG.
- **Redis SG**: 6379 from the app SG only.
- **Node SG**: 443 from the cluster SG. Add an EKS `kubernetes_access` rule for Actions
  egress ranges, or your CI verification steps time out.
- **No IAM users with access keys.** Humans use IAM Identity Center.

### Encryption everywhere

```hcl
resource "aws_kms_key" "main" {
  description             = "myapp data encryption"
  enable_key_rotation     = true
  deletion_window_in_days = 30
}

resource "aws_ebs_encryption_by_default" "on" {}   # catches volumes you forget
resource "aws_ebs_default_kms_key" "main" { key_arn = aws_kms_key.main.arn }
```

Setting the account-wide EBS default is deliberate: it catches the volume someone creates
by hand in the console at 2am, which is exactly the one that ships unencrypted.

### Supply chain

- Every action pinned to a SHA — **including the ones you added in Level 1**
- `gitleaks detect` in CI over full history, not just the diff
- Branch protection on `main`: require `ci.yml` status checks, require review, forbid force-push
- ECR scan-on-push with a threshold that actually blocks deploys

### Verify, do not assume

```bash
# does a fork PR reach AWS?
#   -> open a PR from a fork, confirm no assume-role succeeds

# can CI touch the cluster?
aws accessanalyzer simulate-principal-policy ...

# can any pod read secrets?
kubectl -n app exec deploy/myapp -- aws sts get-caller-identity
#   -> should fail; if it succeeds you are on a node IAM role, not Pod Identity

# are there standing admins?
aws eks list-access-entries --cluster-name myapp-dev
```

---

## Phase 8 — Observability + reliability

Nothing in the requirements asks for observability. That is why it is here.

### Enable, do not install

| Signal | Choice | Why not the alternative |
| --- | --- | --- |
| Metrics | CloudWatch + Container Insights | Prometheus + Grafana = 2 more stateful components to run |
| Logs | CloudWatch Logs | ELK/OpenSearch = a JVM cluster to operate |
| Traces | none yet | Not justified at this scale |
| Alerting | CloudWatch alarms → SNS | 3 alarms is all you need |

"The native managed services cover this without adding operational surface" is a stronger
answer than a list of tools. The tools are only justified when you can name the requirement
they meet.

### Control plane logs — the audit trail nobody enables

```hcl
resource "aws_cloudwatch_log_group" "eks" {
  name              = "/aws/eks/myapp-dev/cluster"
  retention_in_days = 30        # NOT "forever" — this is a real line item
}

# enable all five types; 'audit' is the one that answers "who deleted that deployment"
```

### Three alarms, not thirty

| Alarm | Condition | Why |
| --- | --- | --- |
| Node unhealthy | EKS `cluster_failed_system_status` metric | Losing nodes silently is the top cause of downtime |
| App 5xx rate | ALB/NLB `HTTPCode_Target_5XX_Count` > threshold | Real user-facing breakage |
| Pod OOM | `OOMKilled` container state | Your app has a memory leak; know before customers do |

Plus a budget alarm — cost explosions are silent until the bill arrives.

```hcl
resource "aws_budgets_budget" "monthly" {
  name         = "myapp-monthly"
  budget_type  = "COST"
  limit_amount = "300"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"
  notification {
    comparison_operator = "GREATER_THAN"
    threshold           = 80          # and a second at 100
    threshold_type      = "PERCENTAGE"
  }
}
```

### Backups — perform a restore, do not just configure it

```bash
aws rds create-db-snapshot --db-instance-identifier myapp-dev   --db-snapshot-identifier manual-before-migration
# restore it to a scratch instance and verify the row count
```

A backup you have never restored is a hypothesis. This takes 15 minutes and it is the only
way to know your RPO is real. Record the wall-clock time — that number is your RTO.

### Drift detection

```yaml
name: drift
on:
  schedule: [{ cron: '17 6 * * 1' }]    # Mondays 06:17 — odd minutes avoid the stampede
  workflow_dispatch: {}
permissions: { contents: read, id-token: write }
jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: aws-actions/configure-aws-credentials@v4
        with: { role-to-assume: <infra-plan role>, aws-region: eu-west-1 }
      - run: terraform init && terraform plan -detailed-exitcode
        working-directory: infra/envs/prod
        # exit 2 = changes present. Fail the run so someone looks.
```

Off-hour cron is a small habit that avoids every job on the planet firing at 06:00.

---

## Exit criteria

- [ ] `values.yaml` changes only via Image Updater commits — verify by building without deploying
- [ ] `git revert <merge-sha>` demonstrably rolls the app back
- [ ] A migration runs as a PostSync hook and the sync waits for it
- [ ] Readiness probe fails when the database is unreachable — **prove it**
- [ ] Replicas scale 2 → 4 → 2 under load
- [ ] `https://` validates with no browser warning; TLS 1.2 minimum
- [ ] NLB health check uses `/ready`
- [ ] A pod without the right label **cannot** reach RDS
- [ ] `gitleaks` clean across full Git history
- [ ] The CI role **cannot** touch the EKS cluster (verified by simulation)
- [ ] No human holds standing `cluster-admin`; break-glass path documented
- [ ] Container Insights shows per-pod metrics; the 3 alarms fire correctly in a test
- [ ] A backup was restored and row counts verified
- [ ] Weekly drift workflow reports no changes

---

## Common failures at this stage

| Symptom | Cause | Fix |
| --- | --- | --- |
| Commit on every build | AIU `updateStrategy: newest-build` on SHA tags | `semver` + `allowTags` regex |
| AIU writes nothing | Legacy annotations on v1.x; or `spec.namespace` ≠ `metadata.namespace` | Use `ImageUpdater` CR; drop `spec.namespace` |
| Sync hangs on one component | Missing sync waves | Order ESO → data → app |
| Every deploy has brief 502s | Readiness probe does not check the database | Add `/ready` |
| Pods restart after 30s | Liveness probe checking a dependency | Point liveness at `/healthz`, readiness at `/ready` |
| PVC stuck `Terminating` | In-pod database + AZ failure | Another reason to use RDS |
| Migration Job re-runs forever | `backoffLimit` unset | `backoffLimit: 0` — never auto-retry a migration |
| 502 from the NLB | Target type `instance` with pod IPs | `target_type = "ip"` |
| ACM cert fails DNS validation | Validation record not created, or wrong zone | Use DNS-01 with a Route 53 record |
| Lets Encrypt `too many certificates` | Rate limit during iteration | Use the **staging** endpoint in development |
| NetworkPolicy has no effect | VPC CNI not enforcing | Confirm the network policy agent is running |
| Chart upgrade breaks something | Unpinned chart version | Always pin `version` in `helm_release` |

---

## Cost at this level

| Item | Monthly |
| --- | --- |
| EKS control plane | $73 |
| 2 × `t3.medium` (app) + 1 × `t3.large` (system) | ~$170 |
| 3 × NAT gateway | ~$97 |
| RDS `db.t4g.micro` Multi-AZ | ~$40 |
| ElastiCache `cache.t4g.micro` | ~$25 |
| NLB | ~$20 |
| Logs, metrics, ECR, S3, secrets | ~$25 |
| **Total** | **~$450** |

S3/DynamoDB gateway endpoints are free and cut most NAT data charges. Expect a real bill
reduction from those, plus from ECR lifecycle policies and 30-day log retention.
