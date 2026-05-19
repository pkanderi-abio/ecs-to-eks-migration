# ECS → EKS Migration Toolkit

> **Production-grade migration of 47 ECS services to EKS** — zero customer-impacting downtime, $12,800/month saved, 12-week execution with real incidents, rollbacks, and automation.

[![Terraform](https://img.shields.io/badge/Terraform-1.7+-7B42BC?logo=terraform)](https://terraform.io)
[![Kubernetes](https://img.shields.io/badge/Kubernetes-1.29-326CE5?logo=kubernetes)](https://kubernetes.io)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![GitHub Stars](https://img.shields.io/github/stars/pkanderi-abio/ecs-to-eks-migration)](https://github.com/pkanderi-abio/ecs-to-eks-migration)

---

## 📋 Table of Contents

- [Architecture Overview](#architecture-overview)
- [Prerequisites](#prerequisites)
- [Repository Structure](#repository-structure)
- [Migration Phases](#migration-phases)
- [Quick Start](#quick-start)
- [Terraform Modules](#terraform-modules)
- [Helm Charts](#helm-charts)
- [CI/CD Pipelines](#cicd-pipelines)
- [Incidents & Runbooks](#incidents--runbooks)
- [Cost Comparison](#cost-comparison)
- [Security & Compliance](#security--compliance)
- [Contributing](#contributing)

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                    BEFORE (ECS Era)                              │
│  Route53 → ALB → ECS Cluster (EC2 + Fargate)                   │
│  47 services │ ~180 tasks │ $34,200/month compute               │
│  Secrets: 612 SSM parameters │ CI: GitHub Actions → ECS deploy  │
└─────────────────────────────────────────────────────────────────┘
                              ↓  12 weeks
┌─────────────────────────────────────────────────────────────────┐
│                    AFTER (EKS Era)                               │
│  Route53 → ALB (AWS LBC) → EKS 1.29 + Karpenter               │
│  47 services │ Argo Rollouts canary │ $21,400/month compute     │
│  Secrets: ESO + AWS SM │ CI: GitHub Actions → Helm + Rollouts   │
│  71% Spot utilization │ Calico network policies │ KEDA autoscale│
└─────────────────────────────────────────────────────────────────┘
```

**Key design decisions:**
- EKS provisioned in **same VPC** as ECS — shared RDS/ElastiCache endpoints, zero data layer changes
- **6-week parallel run** — both platforms live simultaneously with weighted Route53
- Argo Rollouts **AnalysisTemplates** auto-rollback on >1% error rate or p99 > 500ms
- Karpenter **NodePool** with Spot+On-Demand mixed, arm64+amd64 instance flexibility

---

## Prerequisites

| Tool | Version | Purpose |
|------|---------|---------|
| Terraform | >= 1.7 | Infrastructure provisioning |
| kubectl | >= 1.29 | Kubernetes CLI |
| helm | >= 3.14 | Chart deployments |
| AWS CLI | >= 2.15 | AWS operations |
| Python | >= 3.11 | Migration scripts |
| jq | any | JSON processing in scripts |
| argo CLI | >= 1.7 | Rollout management |

### AWS Permissions Required
```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": ["eks:*", "ec2:*", "iam:*", "ecr:*",
      "elasticloadbalancing:*", "route53:*", "secretsmanager:*",
      "ssm:GetParametersByPath", "kms:*"], "Resource": "*" }
  ]
}
```

---

## Repository Structure

```
ecs-to-eks-migration/
├── README.md
├── MIGRATION_CHECKLIST.md          # 87-item pre/during/post checklist
├── terraform/
│   ├── modules/
│   │   ├── eks-cluster/            # EKS 1.29, IRSA, managed nodes
│   │   ├── karpenter/              # NodePool + EC2NodeClass
│   │   ├── vpc-cni-addon/          # IPv4 prefix delegation
│   │   ├── alb-controller/         # AWS LBC v2.7 via IRSA
│   │   └── external-dns/           # Route53 sync
│   └── environments/
│       ├── prod/                   # Production cluster config
│       └── staging/                # Staging cluster config
├── helm/
│   ├── charts/
│   │   ├── api-gateway/
│   │   ├── auth-service/
│   │   ├── billing-service/
│   │   ├── notification-service/
│   │   ├── report-generation-service/
│   │   └── tenant-template/        # Helmfile template for 12 tenants
│   └── platform/
│       ├── prometheus-stack/       # kube-prometheus-stack values
│       ├── argo-rollouts/
│       ├── keda/
│       └── external-secrets/
├── k8s/
│   ├── namespaces/                 # NS + LimitRange + ResourceQuota
│   ├── network-policies/           # Calico deny-all + allow rules
│   ├── external-secrets/           # ESO ClusterSecretStore + CRs
│   ├── rollouts/                   # Argo Rollout CRs + Analysis
│   ├── keda-scalers/               # ScaledObject per service
│   ├── rbac/                       # Roles + RoleBindings
│   └── node-local-dns/             # NodeLocalDNSCache daemonset
├── scripts/
│   ├── migrate-ssm-to-secrets.sh   # 612 SSM → AWS SM
│   ├── ecs-task-to-k8s-manifest.py # ECS task def → K8s YAML
│   ├── traffic-shift.sh            # Weighted Route53 updater
│   ├── validate-rollout.sh         # Smoke tests + health check
│   └── cleanup-ecs.sh              # Post-migration ECS teardown
├── .github/
│   └── workflows/
│       ├── terraform-plan.yml      # PR: plan only
│       ├── eks-deploy.yml          # Push to main: Helm upgrade
│       └── rollback.yml            # Manual rollback trigger
└── docs/
    ├── runbook-migration.md
    ├── incident-001-coredns.md
    ├── incident-002-pvc-mount.md
    └── cost-analysis.md
```

---

## Migration Phases

| Phase | Weeks | Description | Status |
|-------|-------|-------------|--------|
| 0 — Planning | 1 | Inventory all ECS services, map dependencies, establish KPIs | ✅ |
| 1 — Foundation | 1–3 | EKS cluster, Karpenter, ALB controller, ESO, Prometheus stack | ✅ |
| 2 — Secrets | 3–4 | 612 SSM → AWS Secrets Manager + ExternalSecrets operator | ✅ |
| 3 — Canary traffic | 4–9 | Per-service canary rollout at 5% → 25% → 50% → 100% | ✅ |
| 4 — Full cutover | 10–12 | All 47 services 100% EKS, ECS scaled to 0 | ✅ |
| 5 — ECS teardown | 12+ | Remove ECS clusters, task defs, unused SGs | ✅ |

---

## Quick Start

```bash
# 1. Clone
git clone https://github.com/pkanderi-abio/ecs-to-eks-migration.git
cd ecs-to-eks-migration

# 2. Configure AWS credentials
export AWS_PROFILE=prod-admin
export AWS_REGION=us-east-1

# 3. Provision EKS cluster
cd terraform/environments/prod
terraform init
terraform plan -out=tfplan
terraform apply tfplan

# 4. Configure kubectl
aws eks update-kubeconfig --name prod-eks-us-east-1 --region us-east-1

# 5. Bootstrap platform tooling
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add argo https://argoproj.github.io/argo-helm
helm repo add kedacore https://kedacore.github.io/charts
helm repo add external-secrets https://charts.external-secrets.io
helm repo update

# Install platform stack
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -f helm/platform/prometheus-stack/values.yaml \
  --namespace monitoring --create-namespace

helm upgrade --install argo-rollouts argo/argo-rollouts \
  -f helm/platform/argo-rollouts/values.yaml \
  --namespace argo-rollouts --create-namespace

helm upgrade --install keda kedacore/keda \
  -f helm/platform/keda/values.yaml \
  --namespace keda --create-namespace

helm upgrade --install external-secrets external-secrets/external-secrets \
  -f helm/platform/external-secrets/values.yaml \
  --namespace external-secrets --create-namespace

# 6. Migrate SSM secrets (dry run first)
./scripts/migrate-ssm-to-secrets.sh true
# Then actual migration:
./scripts/migrate-ssm-to-secrets.sh false

# 7. Apply base k8s manifests
kubectl apply -f k8s/namespaces/
kubectl apply -f k8s/rbac/
kubectl apply -f k8s/network-policies/
kubectl apply -f k8s/external-secrets/
kubectl apply -f k8s/node-local-dns/

# 8. Deploy first service (api-gateway) with canary
helm upgrade --install api-gateway helm/charts/api-gateway \
  --namespace platform \
  --values helm/charts/api-gateway/values-prod.yaml

# 9. Watch rollout
kubectl argo rollouts get rollout api-gateway -n platform --watch
```

---

## Terraform Modules

### eks-cluster
Provisions EKS 1.29 with IRSA, private endpoint, EBS CSI driver, VPC-CNI with prefix delegation.

### karpenter
NodePool with Spot+On-Demand, arm64+amd64, m6i/m6g/m7i/m7g/r6i families. Consolidation enabled.

### alb-controller
AWS Load Balancer Controller v2.7 via IRSA. Manages Ingress → ALB + TargetGroupBinding.

### external-dns
ExternalDNS with Route53 IRSA. Syncs Service/Ingress hostnames to Route53 automatically.

---

## Incidents & Runbooks

- [Incident 001 — CoreDNS CNF Storm](docs/incident-001-coredns.md) — P1, resolved in 24min
- [Incident 002 — PVC EFS Mount Failure](docs/incident-002-pvc-mount.md) — P2, resolved in 13min
- [Full Migration Runbook](docs/runbook-migration.md)

---

## Cost Comparison

| Category | ECS (Before) | EKS (After) | Delta |
|----------|-------------|-------------|-------|
| Compute | $28,400 | $16,200 | -43% |
| Fargate | $4,100 | $0 | -100% |
| Data transfer | $1,700 | $1,400 | -18% |
| **Total/month** | **$34,200** | **$21,400** | **-37%** |
| **Annual savings** | | | **$152,400** |

Spot utilization: **71%** of compute (impossible on Fargate).

---

## Security & Compliance

- ✅ HIPAA — private cluster endpoint, KMS encryption at rest, VPC flow logs
- ✅ SOC 2 CC6/CC7 — RBAC least-privilege, network policies, audit logging to CloudWatch
- ✅ Secrets — AWS KMS CMK for all Secrets Manager secrets, 30-day rotation enabled
- ✅ Images — Trivy scan in CI pipeline, CRITICAL/HIGH CVEs block deployment
- ✅ Network — Calico deny-all default + explicit allow rules per service

---

## License

MIT — use freely, attribution appreciated.
