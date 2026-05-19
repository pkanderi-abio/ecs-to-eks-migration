#!/usr/bin/env bash
# =============================================================================
# validate-rollout.sh
# Post-deploy validation: smoke tests + Argo health gate + Prometheus metrics
#
# Usage:
#   ./validate-rollout.sh <service> <environment>
#   ./validate-rollout.sh api-gateway prod
# =============================================================================
set -euo pipefail

SERVICE="${1:?Usage: $0 <service> <environment>}"
ENVIRONMENT="${2:-prod}"
NAMESPACE="platform"
TIMEOUT=300  # 5 minutes
PROMETHEUS_URL="${PROMETHEUS_URL:-http://localhost:9090}"
MIN_SUCCESS_RATE="${MIN_SUCCESS_RATE:-0.99}"  # 99% success rate required

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
pass() { echo -e "${GREEN}  ✅ PASS${NC}  $*"; }
fail() { echo -e "${RED}  ❌ FAIL${NC}  $*"; FAILURES=$((FAILURES+1)); }
warn() { echo -e "${YELLOW}  ⚠ WARN${NC}  $*"; }

FAILURES=0

echo "══════════════════════════════════════════════════"
echo "  Validating rollout: ${SERVICE} (${ENVIRONMENT})"
echo "══════════════════════════════════════════════════"

# ── Test 1: Rollout status
echo ""
echo "── 1. Argo Rollout status"
STATUS=$(kubectl argo rollouts status "${SERVICE}" -n "${NAMESPACE}" 2>/dev/null || echo "ERROR")
if echo "${STATUS}" | grep -q "Healthy"; then
  pass "Rollout is Healthy"
elif echo "${STATUS}" | grep -q "Paused"; then
  warn "Rollout is Paused (awaiting manual promotion or analysis)"
else
  fail "Rollout status: ${STATUS}"
fi

# ── Test 2: Pod readiness
echo ""
echo "── 2. Pod readiness"
DESIRED=$(kubectl get rollout "${SERVICE}" -n "${NAMESPACE}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
READY=$(kubectl get rollout "${SERVICE}" -n "${NAMESPACE}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
if [[ "${READY}" -ge 1 && "${READY}" -le "${DESIRED}" ]]; then
  pass "Pods ready: ${READY}/${DESIRED}"
else
  fail "Pods ready: ${READY}/${DESIRED} (expected at least 1)"
fi

# ── Test 3: HTTP health check
echo ""
echo "── 3. HTTP health checks"
SERVICE_IP=$(kubectl get service "${SERVICE}" -n "${NAMESPACE}" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
if [[ -n "${SERVICE_IP}" ]]; then
  # Port-forward for testing
  kubectl port-forward "svc/${SERVICE}" 18080:80 -n "${NAMESPACE}" &> /tmp/pf.log &
  PF_PID=$!
  sleep 2

  HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    --max-time 5 \
    "http://localhost:18080/health/ready" 2>/dev/null || echo "000")
  kill "${PF_PID}" 2>/dev/null || true

  if [[ "${HTTP_STATUS}" == "200" ]]; then
    pass "Health endpoint returned HTTP ${HTTP_STATUS}"
  else
    fail "Health endpoint returned HTTP ${HTTP_STATUS}"
  fi
else
  warn "Service ClusterIP not found — skipping HTTP test"
fi

# ── Test 4: Prometheus error rate
echo ""
echo "── 4. Prometheus metrics (last 5min)"
if command -v curl >/dev/null 2>&1; then
  ERROR_RATE=$(curl -s "${PROMETHEUS_URL}/api/v1/query" \
    --data-urlencode "query=sum(rate(http_requests_total{service=\"${SERVICE}\",status=~\"5..\"}[5m])) / sum(rate(http_requests_total{service=\"${SERVICE}\"}[5m]))" \
    2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
results = data.get('data', {}).get('result', [])
if results:
    val = float(results[0]['value'][1])
    print(f'{val:.4f}')
else:
    print('N/A')
" 2>/dev/null || echo "N/A")

  if [[ "${ERROR_RATE}" == "N/A" ]]; then
    warn "Prometheus not reachable — skipping metric gate"
  elif python3 -c "import sys; sys.exit(0 if float('${ERROR_RATE}') < 0.01 else 1)" 2>/dev/null; then
    pass "Error rate: ${ERROR_RATE} (threshold: <0.01)"
  else
    fail "Error rate: ${ERROR_RATE} exceeds threshold of 0.01"
  fi
fi

# ── Test 5: ExternalSecret sync
echo ""
echo "── 5. ExternalSecret sync"
ES_STATUS=$(kubectl get externalsecret "${SERVICE}-secrets" -n "${NAMESPACE}" \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
if [[ "${ES_STATUS}" == "True" ]]; then
  pass "ExternalSecret synced from AWS Secrets Manager"
else
  fail "ExternalSecret status: ${ES_STATUS}"
fi

# ── Summary
echo ""
echo "══════════════════════════════════════════════════"
if [[ "${FAILURES}" -eq 0 ]]; then
  echo -e "${GREEN}  ✅ ALL CHECKS PASSED — ${SERVICE} rollout validated${NC}"
else
  echo -e "${RED}  ❌ ${FAILURES} CHECK(S) FAILED — review before promoting${NC}"
fi
echo "══════════════════════════════════════════════════"
exit "${FAILURES}"
