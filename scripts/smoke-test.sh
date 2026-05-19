#!/usr/bin/env bash
# smoke-test.sh — Basic connectivity smoke tests per service
set -euo pipefail
SERVICE="${1:?service required}"
ENV="${2:-staging}"
NAMESPACE="platform"

echo "Running smoke tests for ${SERVICE} in ${ENV}..."

# Port-forward and test
kubectl port-forward "svc/${SERVICE}" 19090:80 -n "${NAMESPACE}" &>/dev/null &
PF_PID=$!; sleep 3; trap "kill ${PF_PID} 2>/dev/null" EXIT

for ENDPOINT in /health/ready /health/live; do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://localhost:19090${ENDPOINT}" || echo "000")
  [[ "${STATUS}" == "200" ]] && echo "✅ ${ENDPOINT} → ${STATUS}" || echo "❌ ${ENDPOINT} → ${STATUS}"
done
