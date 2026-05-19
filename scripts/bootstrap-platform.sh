#!/usr/bin/env bash
# =============================================================================
# bootstrap-platform.sh
# Installs all platform tooling on a fresh EKS cluster in dependency order:
#   1. ExternalSecrets Operator
#   2. Argo Rollouts
#   3. KEDA
#   4. kube-prometheus-stack
#   5. NodeLocalDNSCache (INCIDENT-001 prevention)
# =============================================================================
set -euo pipefail

CLUSTER="${1:-prod-eks-us-east-1}"
REGION="${2:-us-east-1}"

echo "Bootstrapping platform on: ${CLUSTER}"
aws eks update-kubeconfig --name "${CLUSTER}" --region "${REGION}"

# 1. ExternalSecrets Operator
echo "── Installing External Secrets Operator..."
helm repo add external-secrets https://charts.external-secrets.io 2>/dev/null || true
helm upgrade --install external-secrets external-secrets/external-secrets \
  --namespace external-secrets --create-namespace \
  --set installCRDs=true \
  --wait --timeout 5m

# 2. Argo Rollouts
echo "── Installing Argo Rollouts..."
helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
helm upgrade --install argo-rollouts argo/argo-rollouts \
  --namespace argo-rollouts --create-namespace \
  --values helm/platform/argo-rollouts/values.yaml \
  --wait --timeout 5m

# 3. KEDA
echo "── Installing KEDA..."
helm repo add kedacore https://kedacore.github.io/charts 2>/dev/null || true
helm upgrade --install keda kedacore/keda \
  --namespace keda --create-namespace \
  --values helm/platform/keda/values.yaml \
  --wait --timeout 5m

# 4. Prometheus Stack
echo "── Installing kube-prometheus-stack..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm upgrade --install kube-prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  --values helm/platform/prometheus-stack/values.yaml \
  --wait --timeout 10m

# 5. NodeLocalDNSCache (INCIDENT-001 fix — deploy BEFORE any services)
echo "── Deploying NodeLocalDNSCache (INCIDENT-001 prevention)..."
kubectl apply -f k8s/node-local-dns/daemonset.yaml
kubectl rollout status daemonset/node-local-dns -n kube-system --timeout=120s

# 6. Namespaces + ResourceQuotas
echo "── Creating namespaces..."
kubectl apply -f k8s/namespaces/

# 7. RBAC
echo "── Applying RBAC..."
kubectl apply -f k8s/rbac/

# 8. Network Policies
echo "── Applying network policies..."
kubectl apply -f k8s/network-policies/

# 9. ClusterSecretStore
echo "── Creating ClusterSecretStore..."
kubectl apply -f k8s/external-secrets/cluster-secret-store.yaml

echo ""
echo "✅ Platform bootstrap complete"
echo "   Next: run scripts/migrate-ssm-to-secrets.sh, then deploy services"
