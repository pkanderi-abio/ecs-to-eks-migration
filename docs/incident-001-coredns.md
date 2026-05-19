# Incident 001 — CoreDNS CrashLoopBackOff

**Severity:** P1  
**Date:** 2024-09-17 02:14 UTC  
**Duration:** 24 minutes (02:14–02:38 UTC)  
**Customer Impact:** 0 seconds downtime (ECS absorbed 100% traffic via Route53)  
**Root Cause:** DNS query storm from billing-service (2,412 QPS to CoreDNS)

---

## Timeline

| Time (UTC) | Event |
|------------|-------|
| 02:14 | PagerDuty alert: CoreDNS latency_p99 > 2000ms |
| 02:17 | `kubectl get pods -n kube-system` → 2x CoreDNS CrashLoopBackOff |
| 02:18 | Cluster-wide DNS failure. Argo AnalysisRun fails: error_rate=0.43 |
| 02:19 | Argo Rollout auto-reverts billing-service to stable revision |
| 02:19 | Route53 weighted routing absorbs 100% to ECS (already configured) |
| 02:22 | RCA: billing-service generating 2,412 DNS queries/second |
| 02:22 | Root cause: no DNS caching + ndots:5 amplification (5 lookup attempts per query) |
| 02:31 | NodeLocalDNSCache daemonset deployed: `kubectl apply -f k8s/node-local-dns/daemonset.yaml` |
| 02:38 | CoreDNS pods recover. DNS p99 = 8ms. Incident closed |

## Root Cause

ECS services used a resolved IP address for inter-service calls (ECS Service Discovery with DNS caching at the task level). On EKS, billing-service used Kubernetes DNS (`http://auth-service.platform.svc.cluster.local`) without application-level caching.

With `ndots:5` (Kubernetes default), each lookup generates 5 DNS attempts:
1. `auth-service.platform.svc.cluster.local.cluster.local`
2. `auth-service.platform.svc.cluster.local.us-east-1.compute.internal`
3. `auth-service.platform.svc.cluster.local.us-east-1`
4. `auth-service.platform.svc.cluster.local`
5. `auth-service.platform.svc` ← finally resolves

billing-service processes ~480 requests/min, each making 1 downstream DNS call = 2,400 DNS queries/minute (40 QPS). CoreDNS HPA ceiling was 5 replicas × ~500 QPS = ~2,500 QPS total capacity. The billing-service canary at 25% weight was enough to saturate CoreDNS.

## Fix Applied

```bash
kubectl apply -f k8s/node-local-dns/daemonset.yaml
```

NodeLocalDNSCache runs on every node at `169.254.20.10`. It caches positive responses for 30 seconds, negative for 5 seconds, and only forwards cache misses to CoreDNS. Reduces CoreDNS QPS from 2,412 → ~94.

## Prevention

1. **NodeLocalDNSCache deployed before any service** — added to `scripts/bootstrap-platform.sh` step 5
2. **CoreDNS HPA ceiling raised** to 10 replicas
3. **Karpenter userData** pre-configures link-local address on every new node
4. **AnalysisTemplate `error-rate-check`** catches this before 5% → 25% promotion

## Lessons

- ndots:5 amplification is a known EKS footgun. Deploy NodeLocalDNS on day 0, not day 60.
- Services with high downstream call rates need application-level DNS caching (e.g., aiodns, dnspython with cache, or explicit `ndots:2` override in pod spec).
