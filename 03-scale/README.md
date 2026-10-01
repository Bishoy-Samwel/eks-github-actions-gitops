# Level 3 — Scale

**Goal:** nothing here is built on schedule. Every item is deferred until a **measured**
trigger fires. This folder is a decision record, not a backlog.

---

## The rule

Build an item when its trigger fires. Not when it feels like good engineering, and not
because a blog post said it is best practice.

The failure mode this avoids: a system designed for scale it will never see, paid for
monthly, operated daily, and broken in ways you then debug instead of the real problems.
"Production-ready" already means a lot; it does not mean "designed for a million users
you do not have."

Two rules of thumb:

1. **A trigger must be a number you have measured**, not a feeling. "The load is getting
   high" is not a trigger. "p95 latency exceeds 400ms at 200 rps" is.
2. **Prefer the managed service to the thing you would self-host.** Every self-hosted
   component on the trigger list below replaces an AWS service that would otherwise do the
   job for free.

---

## Triggers

### Karpenter

**Trigger:** node provisioning is a visible line on the bill, **or** >20 nodes across
heterogeneous instance types, **or** cluster autoscaler takes >60s to scale up.

Karpenter provisions nodes from instance *families* rather than fixed groups, bins
instances by utilisation, and consolidates them. The wins are real: bin-packing raises
utilisation from a typical 30–40% toward 70%+, and scale-up drops from ~60s to seconds.

**Cost of adding it:** a second autoscaler to learn, a CRD with a large API surface, and a
scheduling behaviour that is not intuitive when it goes wrong. If cluster autoscaler is
keeping up, Karpenter buys you money, not correctness.

**Migration note:** run both for a period with Karpenter's consolidation only — no, run
*cluster autoscaler* with Karpenter provisioning disabled, confirm no regressions, then
switch. Do not run two provisioners against the same node group.

---

### HPA on custom metrics

**Trigger:** CPU-based HPA visibly mispredicts — pods at 15% CPU get killed for memory
pressure, or CPU saturates while requests queue.

A Node.js app is usually memory-bound, so CPU is the wrong signal. Replace it with request
rate or p95 latency using KEDA or Prometheus Adapter.

**Before that:** try `behavior` stabilization windows, and requests/limits tuned to actual
usage from Container Insights. Misconfigured HPA is more often a metrics-config problem
than a missing custom metric.

---

### RDS Proxy or read replicas

**Trigger:** DB `DatabaseConnections` approaching `max_connections`, **or** reads measurably
dominating and cache hit rate is already high.

Each pod holds connections. At 20 replicas plus migrations plus workers you will hit limits
that a vertical resize will not solve.

**Why not Aurora:** RDS Proxy first. Aurora Serverless v2 is a genuine step up but it
changes the engine, the storage behaviour, and the cost model — a bigger decision than a
read replica.

---

### ElastiCache cluster mode / larger nodes

**Trigger:** cache hit rate drops below ~80% at steady load, or `used_memory` approaches
`maxmemory` and evictions spike.

**Before that:** add TTLs and check your invalidation strategy. An unbounded cache is an OOM
before it is a scaling problem.

---

### External ALB + WAF

**Trigger:** you genuinely need L7 — path-based routing across services, host rules, sticky
sessions, header manipulation — **or** a public-facing workload that needs WAF or Shield.

NLB is L4: fast, cheap, no request inspection. WAF and rate limiting at layer 7 require a
layer 7 load balancer. AWS WAF is a significant addition — roughly $5/rule/month plus
request charges, and rules need real thought.

---

### Self-hosted runners

**Trigger:** a workflow step genuinely cannot run outside the VPC — internal API, private
subnet scan, on-premises registration.

**Cost, honestly:** you now maintain and patch a fleet of runners, each holding a scoped
credential, each a place to persist secrets if misconfigured, each needing HA to avoid
being the reason CI is down. The GitHub Actions Runner Controller automates some of this.
It is strictly more work than hosted runners, and the trigger above is a high bar.

**Hosted runners get you 2,000 min/month free on private repos and unlimited on public.**
That budget covers a lot of on-prem reachability before it becomes worth it.

---

### Distributed tracing

**Trigger:** debugging latency across more than ~3 services becomes the bottleneck — you
cannot tell from traces which span is slow, and logs are insufficient.

OTel Collector on the node → Tempo or Jaeger. This is a genuine operational addition: a
collector DaemonSet, a backend to run, cardinality that can get expensive fast.

**Before that:** structured logs with a request ID propagated across services. That answers
a large share of "which call was slow?" for one service and costs nothing.

---

### Chaos engineering

**Trigger:** you have written SLOs and want to *prove* your resilience rather than assume it.

**Before that:** prove it manually. Delete a pod. Drain a node with
`aws eks update-nodegroup-config --drain`. Block the RDS SG. You will find most of your real
bugs in an afternoon, without a framework.

---

### Multi-region

**Trigger:** a stated business requirement, a data-residency regulation, or an RTO that
single-region cannot meet.

**Cost:** a second region means a second EKS control plane ($73), a second set of NAT
gateways (~$97), a second RDS instance with cross-region replication, global load balancing,
and DNS-based failover. **Roughly 3x**, plus the operational surface of two regions and a
failure mode that spans both.

**Do not build this because it is best practice.** Build it when something forces it.

---

### Terraform at scale (states, stacks, Atlantis)

**Trigger:** >1 team deploying, >~50 resources changing per PR, or environment count >3.

| Pattern | Trigger specifically |
| --- | --- |
| Split state by component | Two teams touching the same state file will conflict |
| Terragrunt | DRY across envs, keep Terraform files identical |
| S3 native locking | Drop DynamoDB; one less service |
| `prevent_destroy` + plan files in CI | Already in Level 2 — scale this, do not add it here |

**At this point also:** OIDC roles per team, drift alerts per stack, and a central policy
repository (OPA/Sentinel) so a `0.0.0.0/0` security group cannot reach production.

---

## What stays deliberately unbuilt

Listed so the omission is a decision on record, not an oversight.

| Component | Why not |
| --- | --- |
| Service mesh | One service. Nothing to govern, and mTLS for a single hop is theatre |
| Kafka / any broker | No async fan-out, no event sourcing, no replay requirement |
| Multi-region | No trigger above |
| Canary releases | No traffic to split and no way to measure a variant yet |
| Blue/green | Doubles app capacity for no stated benefit on a 2–4 replica service |
| Chaos framework | Manual failure injection proves more, faster |
| Second IaC tool | Terraform with modules is not the bottleneck |
| API gateway | One ingress already does the job |
| Separate microservices | A Node app with a database is not a monolith that needs splitting |

---

## Pre-scale checklist

Before considering any of the above, confirm the basics are genuinely solid. Scale on top
of a shaky foundation multiplies the shakiness:

- [ ] SLOs written and measured, not guessed
- [ ] `p50 / p95 / p99` latency known under real load
- [ ] Error budget defined and a policy attached to it
- [ ] Load tested to a known ceiling, and you know where it breaks
- [ ] On-call runbook exists and someone other than you has read it
- [ ] Restore tested within the last 30 days
- [ ] Terraform plan reviewed and applied by someone who did not write it
- [ ] No `terraform apply` run from a laptop as a matter of routine
