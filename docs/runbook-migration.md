# Migration Runbook — ECS → EKS

**Last updated:** 2024-11-01  
**Owner:** Platform Team  
**Compliance:** SOC 2 CC7.1 | HIPAA §164.312

---

## Pre-migration Checklist

- [ ] EKS cluster provisioned in same VPC as ECS (`terraform apply`)
- [ ] Karpenter deployed and NodePool active
- [ ] NodeLocalDNSCache deployed (`k8s/node-local-dns/daemonset.yaml`) — **do this FIRST (INCIDENT-001 prevention)**
- [ ] ExternalSecrets Operator installed + ClusterSecretStore configured
- [ ] SSM → Secrets Manager migration complete (`scripts/migrate-ssm-to-secrets.sh /prod us-east-1 true`)
- [ ] Argo Rollouts installed + kubectl plugin installed
- [ ] KEDA installed
- [ ] kube-prometheus-stack installed + Grafana dashboards imported
- [ ] Namespaces + ResourceQuotas + NetworkPolicies applied
- [ ] EFS Security Group rule added for EKS nodes (INCIDENT-002 prevention)

## Per-Service Migration Steps

For each service, in priority order (lowest traffic → highest):

### 1. Generate K8s manifests
```bash
python3 scripts/ecs-task-to-k8s-manifest.py \
  --task-def <family>:latest \
  --region us-east-1 \
  --output-dir /tmp/generated
```
Review and move to `helm/charts/<service>/` or `k8s/`.

### 2. Create ExternalSecret
```bash
# Copy and edit template
cp k8s/external-secrets/api-gateway.yaml k8s/external-secrets/<service>.yaml
# Edit: name, secret name, SM secret key
kubectl apply -f k8s/external-secrets/<service>.yaml
# Verify sync
kubectl get externalsecret <service>-secrets -n platform
```

### 3. Deploy to EKS (initial, 0% traffic)
```bash
helm upgrade --install <service> ./helm/charts/<service> \
  --namespace platform \
  --set image.tag=<current-prod-tag> \
  --wait
```

### 4. Verify pods healthy
```bash
kubectl get pods -n platform -l app=<service>
kubectl logs -n platform -l app=<service> --tail=50
./scripts/validate-rollout.sh <service> prod
```

### 5. Shift 5% traffic to EKS
```bash
./scripts/traffic-shift.sh <service> 5
```
Monitor for 15 minutes. Check Grafana dashboard.

### 6. Progressive rollout (5 → 25 → 50 → 100)
```bash
# After 15 min observation at 5%:
./scripts/traffic-shift.sh <service> 25
# After 30 min observation at 25%:
./scripts/traffic-shift.sh <service> 50
# After 1h observation at 50%:
./scripts/traffic-shift.sh <service> 100
```

### 7. Decommission ECS service
```bash
# Only after 48h at 100% EKS with no incidents
aws ecs update-service \
  --cluster prod-ecs-cluster \
  --service <service> \
  --desired-count 0 \
  --region us-east-1
# After 1 week: delete the service
aws ecs delete-service \
  --cluster prod-ecs-cluster \
  --service <service> \
  --force \
  --region us-east-1
```

## Emergency Rollback

### Via GitHub Actions (preferred)
Go to **Actions** → **Emergency Rollback** → **Run workflow** → enter service name + reason.

### Via CLI (immediate)
```bash
# Rollback Argo Rollout to stable
kubectl argo rollouts abort <service> -n platform
kubectl argo rollouts undo <service> -n platform

# Shift 100% traffic back to ECS
./scripts/traffic-shift.sh <service> 0
```

## Monitoring Dashboards

- **Grafana:** http://grafana.internal/d/eks-migration (canary vs stable comparison)  
- **Argo Rollouts UI:** `kubectl argo rollouts dashboard` (port 3100)  
- **CloudWatch:** `/aws/eks/prod-eks-us-east-1/cluster`

## Contacts

| Role | Contact |
|------|---------|
| Platform Lead | @platform-team (Slack) |
| On-call | PagerDuty: Platform Engineering |
| AWS TAM | via AWS Support case |
