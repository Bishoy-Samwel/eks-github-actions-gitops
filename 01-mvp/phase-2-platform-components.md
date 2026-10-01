# Phase 2 — Cluster Platform Components

**Goal:** the controllers that everything else depends on, installed by Terraform.

**Depends on:** Phase 1 · **Blocks:** Phase 4 (GitOps), Phase 5 (secrets, app deploy)

---

## The bootstrap boundary

These are installed by **Terraform's Helm provider**, not by Argo CD.

Argo CD cannot install itself — the chicken-and-egg problem. Something has to place the
first controller in the cluster, and that something is Terraform. Drawing the line here is
what keeps the architecture coherent:

| Installed by Terraform | Installed by Argo CD |
| --- | --- |
| Argo CD itself | Your applications |
| Argo CD Image Updater | Their sync waves |
| External Secrets Operator | Their ExternalSecret CRs |
| Ingress controller | Ingress resources |
| cert-manager | Certificate resources |
| Load Balancer Controller | (nothing — it reacts to Ingress) |

**Terraform owns the platform. Argo CD owns the workloads.** If Terraform also manages an
app Deployment, GitOps has two sources of truth and the second one silently wins.

---

## What to install

```hcl
locals {
  helm_components = {
    "external-secrets"     = { chart = "external-secrets",     version = "0.10.5" }
    "external-secrets-crds" = { chart = "external-secrets-crds", version = "0.10.5" }
    "argo-cd"              = { chart = "argo-cd",              version = "7.3.5" }
    "argocd-image-updater" = { chart = "argocd-image-updater", version = "1.0.1" }
    "ingress-nginx"        = { chart = "ingress-nginx",        version = "4.11.3" }
  }
}

resource "helm_release" "components" {
  for_each = local.helm_components

  name       = each.key
  repository = "https://charts.bitnami.com/bitnami"
  chart      = each.value.chart
  version    = each.value.version      # ALWAYS pinned. A floating chart is a surprise deploy.
  namespace  = "argocd"
  timeout    = 600
}
```

**Pin `version`.** An unpinned chart resolves to the newest release at apply time, which
means your Terraform run can install a different version than last week with no diff in your
code. This is the same class of bug as an unpinned image tag, and it is harder to spot.

Two of these deserve individual attention.

### External Secrets — CRDs first

```hcl
resource "helm_release" "external_secrets_crds" {
  # ...must be applied BEFORE external-secrets, or the controller crashes on a missing CRD
  name    = "external-secrets-crds"
  chart   = "external-secrets-crds"
  version = "0.10.5"
}

resource "helm_release" "external_secrets" {
  depends_on = [helm_release.external_secrets_crds]   # explicit, even with for_each
}
```

With `for_each` Terraform has no inherent ordering between map elements. Either split them
into two resources with `depends_on`, or accept that the CRD chart may land second and the
controller will crash-loop until you re-apply. Crashing is recoverable; not knowing why is
not.

### Argo CD Image Updater — v1.x is CRD-based

```hcl
resource "helm_release" "argocd_image_updater" {
  name    = "argocd-image-updater"
  chart   = "argocd-image-updater"
  version = "1.0.1"      # 1.x. Not 0.17. See below.

  set {
    name  = "config.argocdServer"
    value = "argocd-server"
  }
}
```

**Version 1.0 was a breaking change.** Image Updater moved from annotations on the
`Application` to a dedicated `ImageUpdater` custom resource. If you follow an older example
you will configure it with `argocd.argoproj.io/image-list` annotations and it will appear to
install correctly while silently doing nothing.

You do not write the `ImageUpdater` CR in this phase — that is Phase 4, once there is an
image to track. But pin 1.x now so you are not debugging an old chart later.

---

## The generic wrapper module

Worth writing even at MVP scale, because it is what makes the `for_each` above possible.

```hcl
# modules/helm-release/main.tf
variable "name"        { type = string }
variable "repository"  { type = string }
variable "chart"       { type = string }
variable "version"     { type = string }
variable "namespace"   { type = string }
variable "extra_values" {
  type    = any
  default = {}
}

resource "helm_release" "this" {
  name             = var.name
  repository       = var.repository
  chart            = var.chart
  version          = var.version
  namespace        = var.namespace
  create_namespace = true
  timeout          = 600

  values = concat(
    [file("${path.module}/values/${var.name}.yaml")],
    var.extra_values == {} ? [] : [yamlencode(var.extra_values)],
  )

  atomic          = true     # roll back a failed upgrade instead of leaving it half-done
  cleanup_on_fail = true     # do not leave a failed release's resources behind
}
```

`atomic` and `cleanup_on_fail` are the two settings people omit and then regret. Without
them, a failed chart upgrade leaves the resource in whatever state it reached.

---

## The open question: how does the first Application get created?

The Argo CD Helm chart installs the **controllers**. It does not create your `Application`
objects. Pick one, and write the answer down — "how does the first Application get created"
is a standard question and "I clicked it in the UI" is a weaker answer than "here is the
manifest."

**Option A — ship Applications in the chart** (fully declarative, but the chart becomes
responsible for your app config):

```yaml
# values/argo-cd.yaml
server:
  extraArgs:
    application.namespaces: argocd
  repositories: |
    - type: git
      url: https://github.com/ORG/REPO.git
```

**Option B — a bootstrap Application** (the app-of-apps pattern; Argo CD manages itself once
running):

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: bootstrap
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/ORG/REPO.git
    targetRevision: main
    path: argocd/root            # dir containing more Application manifests
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated: { prune: true, selfHeal: true }
```

**Option C — apply one Application once by hand** (fine for MVP; document it as manual).

For MVP, Option C is defensible and fastest. For Level 2, move to Option B.

### Private repo access

If the repo is private — and it should be — Argo CD needs a credential:

```bash
kubectl -n argocd create secret generic repo-cred   --from-literal=url=https://github.com/ORG/REPO.git   --from-literal=username=x-access-token   --from-literal=password=<PAT or GitHub App token>
```

Better, at Level 2: put this token in Secrets Manager and project it with ESO. That is the
whole point of having ESO, and using it for the Argo CD credential is its most natural first
application.

---

## Verify before moving on

```bash
# 1. Every release is actually deployed, not just "exists"
helm list -A
#    STATUS must be "deployed". A release can be "deployed" while pods crash-loop.

# 2. Pods are running, not just present
kubectl get pods -A -o wide

# 3. Image Updater CRDs registered — this is the v1.x check
kubectl get crd | grep argocd-image-updater
#    -> imagestupaters.argocd-image-updater.argoproj.io

# 4. ESO can reach AWS via Pod Identity
kubectl -n argocd logs deploy/external-secrets | grep -i "unable\|error"
#    -> should be silent

# 5. Argo CD API responds
kubectl -n argocd port-forward svc/argocd-server 8080:80 &
curl -s localhost:8080/api/version | jq .

# 6. Image Updater can talk to Argo CD and ECR
kubectl -n argocd logs deploy/argocd-image-updater | grep -i "error\|denied"
```

Check 1 is the one that catches the most trouble. `helm list` showing `deployed` tells you
the chart applied. It does not tell you the application inside is working. Check 2 is the
one that actually answers "is this thing alive."

---

## Exit criteria

- [ ] `helm list -A` shows every release `deployed`
- [ ] All controller pods `Running` with no restarts
- [ ] `kubectl get crd` shows the Image Updater CRD (v1.x)
- [ ] External Secrets controller has no AWS errors in its logs
- [ ] Argo CD API responds at `/api/version`
- [ ] Every chart version pinned — no floating versions
- [ ] `atomic = true` and `cleanup_on_fail = true` on the wrapper
- [ ] You can state in one sentence how the first Application is created
- [ ] Argo CD can reach the private repo (credential configured)

---

## Common failures

| Symptom | Cause | Fix |
| --- | --- | --- |
| ESO pod crash-loops | CRD chart applied after the controller | Split into two `helm_release` resources with `depends_on` |
| ESO logs show `AccessDenied` | No Pod Identity association for the ESO service account | Create a `aws_eks_pod_identity_association` in Phase 1's module |
| Image Updater installed, writes nothing | 0.x chart with annotations, or v1.x with annotation config | Use 1.x and the `ImageUpdater` CR. Annotations are ignored |
| Image Updater cannot reach Argo CD | Server address wrong | `config.argocdServer=argocd-server` in the chart values |
| Argo CD cannot reach Git | Private repo, no credential | `repo-cred` Secret in the `argocd` namespace |
| Argo CD `OutOfSync` on everything | Repository URL mismatch, or missing value files | Check the exact URL, including `.git`, and the `valueFiles` paths |
| Helm release shows `pending-install` forever | Timeout too low for a slow cluster | `timeout = 600`; check for a stuck Job |
| Chart version differs from last apply | Unpinned `version` | Pin it. Terraform has no diff to show you when a chart moves |
| Upgrade leaves resources behind | `atomic` / `cleanup_on_fail` unset | Both are in the wrapper above |

---

## Cost contribution

No new line items. Helm releases are free; they run on nodes you are already paying for.

**The cost is operational, not financial:** five more controllers, each with its own
upgrade cycle, compatibility matrix, and failure mode. This is the point where "should we
just use ECS" becomes a fair question — the answer here is that GitOps on EKS is what the
design requires, but log it as a cost of the architecture rather than a free choice.

Level 1 total remains **~$208/mo**.
