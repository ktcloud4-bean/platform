#!/usr/bin/env bash
# ==============================================================================
# OBS-20 Live Verification
# ==============================================================================
set -Eeuo pipefail

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/k3s-01-admin.yaml}"
readonly k3s_host="${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}"
readonly known_hosts="${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}"
readonly test_ttl_seconds=40

pass() { echo -e "\033[32m[PASS]\033[0m $*"; }
fail() { echo -e "\033[31m[FAIL]\033[0m $*"; exit 1; }

echo "================================================================"
echo "[OBS-20] Live Verification: ArgoCD & Velero Observability Rules"
echo "================================================================"

# --- Step 1: Verify Argo CD Application Status ---
echo ""
echo "--- Step 1: Verify Argo CD Application Status ---"
OBS_SYNC=$(kubectl -n argocd get application obs -o jsonpath='{.status.sync.status}')
OBS_HEALTH=$(kubectl -n argocd get application obs -o jsonpath='{.status.health.status}')

if [ "${OBS_SYNC}" == "Synced" ] && [ "${OBS_HEALTH}" == "Healthy" ]; then
  pass "Argo CD Application 'obs' is Synced and Healthy"
else
  fail "Argo CD Application 'obs' state: sync=${OBS_SYNC}, health=${OBS_HEALTH}"
fi

# --- Step 2: Verify PrometheusRule Loaded ---
echo ""
echo "--- Step 2: Verify PrometheusRule Loaded & Baseline 0 Firing ---"
kubectl -n obs port-forward svc/obs-prometheus 39190:9090 >/dev/null 2>&1 &
PF_PID=$!
trap 'kill ${PF_PID} 2>/dev/null || true' EXIT
sleep 2

RULES_RESP=$(curl -s "http://127.0.0.1:39190/api/v1/rules" || true)

for rule_name in ArgoCDApplicationDegraded VeleroTargetDown VeleroBackupFreshnessStale; do
  if echo "${RULES_RESP}" | grep -q "\"name\":\"${rule_name}\""; then
    pass "Prometheus rule '${rule_name}' is loaded and active"
  else
    fail "Prometheus rule '${rule_name}' not found in active rules"
  fi
done

# Baseline check: ensure 0 firing for the new rules
ALERTS_RESP=$(curl -s "http://127.0.0.1:39190/api/v1/alerts" || true)
for rule_name in ArgoCDApplicationDegraded VeleroTargetDown VeleroBackupFreshnessStale; do
  IS_FIRING=$(echo "${ALERTS_RESP}" | jq -r --arg r "${rule_name}" '.data.alerts[] | select(.labels.alertname == $r and .state == "firing") | .labels.alertname' 2>/dev/null || true)
  if [ -z "${IS_FIRING}" ]; then
    pass "Baseline check: '${rule_name}' has 0 firing alerts"
  else
    fail "Baseline check failed: '${rule_name}' is currently firing"
  fi
done
kill ${PF_PID} 2>/dev/null || true

# --- Step 3: Verify Alertmanager Test Alert Injection & Resolution ---
echo ""
echo "--- Step 3: Test Alert Injection & Lifecycle (Firing -> Resolved) ---"
kubectl -n obs port-forward svc/obs-alertmanager 39193:9093 >/dev/null 2>&1 &
AM_PID=$!
kubectl -n obs port-forward svc/obs-13-receiver 39180:8080 >/dev/null 2>&1 &
REC_PID=$!
trap 'kill ${AM_PID} ${REC_PID} 2>/dev/null || true' EXIT
sleep 2

get_rec_metric() {
  local status=$1
  local alertname=$2
  curl -s "http://127.0.0.1:39180/metrics" | awk -v alert="${alertname}" -v st="${status}" \
    '$1 ~ "obs13_alerts_received_total" && $1 ~ "alertname=\""alert"\"" && $1 ~ "status=\""st"\"" {print $2}' | tail -n1 || echo "0"
}

TEST_START_EPOCH=$(date -u +%s)
TEST_END_EPOCH=$((TEST_START_EPOCH + test_ttl_seconds))
TEST_START_ISO=$(date -u -d "@${TEST_START_EPOCH}" +%Y-%m-%dT%H:%M:%SZ)
TEST_END_ISO=$(date -u -d "@${TEST_END_EPOCH}" +%Y-%m-%dT%H:%M:%SZ)
TEST_ID="obs20test${TEST_START_EPOCH}"
TARGET_ALERTNAME="ArgoCDApplicationDegraded"

FIRING_BEFORE=$(get_rec_metric "firing" "${TARGET_ALERTNAME}")
RESOLVED_BEFORE=$(get_rec_metric "resolved" "${TARGET_ALERTNAME}")
FIRING_BEFORE=${FIRING_BEFORE:-0}
RESOLVED_BEFORE=${RESOLVED_BEFORE:-0}

echo "[*] Injecting test alert with test_id=${TEST_ID}, TTL=${test_ttl_seconds}s..."
TEST_PAYLOAD=$(cat <<EOF
[
  {
    "labels": {
      "alertname": "${TARGET_ALERTNAME}",
      "severity": "critical",
      "instance": "[TEST] obs-20-test-instance",
      "test": "true",
      "test_id": "${TEST_ID}"
    },
    "startsAt": "${TEST_START_ISO}",
    "endsAt": "${TEST_END_ISO}",
    "generatorURL": "https://grafana.imcherry5778.xyz/alerting/list"
  }
]
EOF
)

curl -s -X POST -H "Content-Type: application/json" -d "${TEST_PAYLOAD}" "http://127.0.0.1:39193/api/v2/alerts" >/dev/null

echo "[*] Waiting for test alert firing in Alertmanager & receiver..."
FIRING_OK=false
for _ in $(seq 1 15); do
  FIRING_NOW=$(get_rec_metric "firing" "${TARGET_ALERTNAME}")
  FIRING_NOW=${FIRING_NOW:-0}
  if [ "${FIRING_NOW}" -gt "${FIRING_BEFORE}" ]; then
    FIRING_OK=true
    break
  fi
  sleep 2
done

if [ "${FIRING_OK}" == "true" ]; then
  pass "Test alert received as firing in receiver (count: ${FIRING_NOW})"
else
  fail "Test alert did not fire in receiver within timeout"
fi

echo "[*] Waiting for test alert TTL expiration and resolution (up to 120s)..."
RESOLVED_OK=false
for _ in $(seq 1 40); do
  RESOLVED_NOW=$(get_rec_metric "resolved" "${TARGET_ALERTNAME}")
  RESOLVED_NOW=${RESOLVED_NOW:-0}
  if [ "${RESOLVED_NOW}" -gt "${RESOLVED_BEFORE}" ]; then
    RESOLVED_OK=true
    break
  fi
  sleep 3
done

if [ "${RESOLVED_OK}" == "true" ]; then
  pass "Test alert resolved successfully in receiver (count: ${RESOLVED_NOW})"
else
  fail "Test alert did not resolve within expected timeout"
fi

kill ${AM_PID} ${REC_PID} 2>/dev/null || true

echo "================================================================"
echo "Verification Summary: All OBS-20 Checks Passed"
echo "================================================================"
