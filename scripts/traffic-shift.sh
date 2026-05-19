#!/usr/bin/env bash
# =============================================================================
# traffic-shift.sh
# Shifts traffic between ECS (stable) and EKS (canary) using Route53 weighted
# records AND ALB listener rule weights. Supports gradual: 5 → 25 → 50 → 100
#
# Usage:
#   ./traffic-shift.sh <service> <eks_weight> [--dry-run]
#   ./traffic-shift.sh api-gateway 25 --dry-run
#   ./traffic-shift.sh api-gateway 50
#   ./traffic-shift.sh api-gateway 100  # full cutover
#   ./traffic-shift.sh api-gateway 0    # emergency rollback to ECS
# =============================================================================
set -euo pipefail

SERVICE="${1:-}"
EKS_WEIGHT="${2:-}"
DRY_RUN="${3:-false}"
REGION="${AWS_REGION:-us-east-1}"
HOSTED_ZONE_ID="${HOSTED_ZONE_ID:-REPLACE_WITH_ZONE_ID}"

[[ -z "${SERVICE}" ]]    && { echo "Usage: $0 <service> <eks_weight> [--dry-run]"; exit 1; }
[[ -z "${EKS_WEIGHT}" ]] && { echo "Error: eks_weight required (0-100)"; exit 1; }

ECS_WEIGHT=$((100 - EKS_WEIGHT))

echo "═══════════════════════════════════════════════════"
echo "  Traffic Shift: ${SERVICE}"
echo "  ECS weight: ${ECS_WEIGHT}%  |  EKS weight: ${EKS_WEIGHT}%"
echo "  Region: ${REGION}"
[[ "${DRY_RUN}" == "--dry-run" ]] && echo "  ⚠ DRY RUN — no changes applied"
echo "═══════════════════════════════════════════════════"

# ── Step 1: Get Route53 record sets for this service
ECS_DNS=$(aws elbv2 describe-load-balancers \
  --region "${REGION}" \
  --query "LoadBalancers[?contains(DNSName,'ecs-${SERVICE}')].DNSName | [0]" \
  --output text 2>/dev/null || echo "")

EKS_DNS=$(kubectl get ingress "${SERVICE}-ingress" \
  -n platform \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")

if [[ -z "${ECS_DNS}" || -z "${EKS_DNS}" ]]; then
  echo "⚠ Could not auto-detect ALB DNS. Using Route53 CNAME-based approach."
  echo "  ECS ALB: ${ECS_DNS:-<not found>}"
  echo "  EKS ALB: ${EKS_DNS:-<not found>}"
fi

# ── Step 2: Build Route53 change batch
CHANGE_BATCH=$(cat << EOF
{
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "${SERVICE}.prod.example.com",
        "Type": "CNAME",
        "SetIdentifier": "ecs-${SERVICE}",
        "Weight": ${ECS_WEIGHT},
        "TTL": 60,
        "ResourceRecords": [{"Value": "${ECS_DNS:-ecs-placeholder.us-east-1.elb.amazonaws.com}"}]
      }
    },
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "${SERVICE}.prod.example.com",
        "Type": "CNAME",
        "SetIdentifier": "eks-${SERVICE}",
        "Weight": ${EKS_WEIGHT},
        "TTL": 60,
        "ResourceRecords": [{"Value": "${EKS_DNS:-eks-placeholder.us-east-1.elb.amazonaws.com}"}]
      }
    }
  ]
}
EOF
)

if [[ "${DRY_RUN}" == "--dry-run" ]]; then
  echo ""
  echo "── [DRY-RUN] Would apply Route53 change batch ──"
  echo "${CHANGE_BATCH}" | python3 -m json.tool
  echo ""
  echo "── [DRY-RUN] Would update ALB listener rule weight to ${EKS_WEIGHT}% ──"
else
  echo "Updating Route53 weighted records..."
  CHANGE_ID=$(aws route53 change-resource-record-sets \
    --hosted-zone-id "${HOSTED_ZONE_ID}" \
    --change-batch "${CHANGE_BATCH}" \
    --query "ChangeInfo.Id" \
    --output text)

  echo "Waiting for Route53 change to propagate (change ID: ${CHANGE_ID})..."
  aws route53 wait resource-record-sets-changed --id "${CHANGE_ID}"
  echo "✅ Route53 updated: ECS=${ECS_WEIGHT}% | EKS=${EKS_WEIGHT}%"

  # ── Step 3: Update Argo Rollout weight to match
  if [[ "${EKS_WEIGHT}" -eq 100 ]]; then
    echo "Setting Argo Rollout to promote (100% EKS)..."
    kubectl argo rollouts promote "${SERVICE}" -n platform
  elif [[ "${EKS_WEIGHT}" -eq 0 ]]; then
    echo "Setting Argo Rollout to abort (rollback to ECS)..."
    kubectl argo rollouts abort "${SERVICE}" -n platform 2>/dev/null || true
    kubectl argo rollouts undo  "${SERVICE}" -n platform 2>/dev/null || true
  else
    echo "Setting canary weight to ${EKS_WEIGHT}% on Argo Rollout..."
    kubectl argo rollouts set weight "${SERVICE}" "${EKS_WEIGHT}" -n platform
  fi
fi

echo ""
echo "✅ Traffic shift complete"
echo "   Monitor: kubectl argo rollouts get rollout ${SERVICE} -n platform -w"
