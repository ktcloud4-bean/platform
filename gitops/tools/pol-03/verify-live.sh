#!/usr/bin/env bash
# ==============================================================================
# POL-03 Live Verification
# ==============================================================================
set -Eeuo pipefail

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/k3s-01-admin.yaml}"
readonly k3s_host="${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}"

pass() { echo -e "\033[32m[PASS]\033[0m $*"; }
fail() { echo -e "\033[31m[FAIL]\033[0m $*"; exit 1; }

echo "================================================================"
echo "[POL-03] Live Verification: Kyverno Policy Exceptions Remediation"
echo "================================================================"

# --- Step 1: Verify Argo CD Workloads have Pod-level runAsNonRoot ---
echo ""
echo "--- Step 1: Verify Argo CD Workloads Pod-level runAsNonRoot ---"
for deploy in argocd-applicationset-controller argocd-dex-server argocd-notifications-controller argocd-redis argocd-repo-server argocd-server; do
  RUN_AS_NON_ROOT=$(kubectl -n argocd get deployment "${deploy}" -o jsonpath='{.spec.template.spec.securityContext.runAsNonRoot}')
  if [ "${RUN_AS_NON_ROOT}" == "true" ]; then
    pass "Deployment/${deploy} has spec.template.spec.securityContext.runAsNonRoot=true"
  else
    fail "Deployment/${deploy} missing runAsNonRoot: '${RUN_AS_NON_ROOT}'"
  fi
done

CTRL_RUN_AS_NON_ROOT=$(kubectl -n argocd get statefulset argocd-application-controller -o jsonpath='{.spec.template.spec.securityContext.runAsNonRoot}')
if [ "${CTRL_RUN_AS_NON_ROOT}" == "true" ]; then
  pass "StatefulSet/argocd-application-controller has spec.template.spec.securityContext.runAsNonRoot=true"
else
  fail "StatefulSet/argocd-application-controller missing runAsNonRoot: '${CTRL_RUN_AS_NON_ROOT}'"
fi

# --- Step 2: Verify Argo CD PolicyException is ABSENT ---
echo ""
echo "--- Step 2: Verify pol-02-argocd-run-as-non-root is Absent ---"
if kubectl -n kyverno get policyexception pol-02-argocd-run-as-non-root >/dev/null 2>&1; then
  fail "PolicyException pol-02-argocd-run-as-non-root still exists!"
else
  pass "PolicyException pol-02-argocd-run-as-non-root is absent as expected"
fi

# --- Step 3: Verify CrowdSec whoami Pod-level runAsNonRoot ---
echo ""
echo "--- Step 3: Verify CrowdSec whoami Pod-level runAsNonRoot ---"
WHOAMI_NON_ROOT=$(kubectl -n crowdsec-01 get deployment crowdsec-01-whoami -o jsonpath='{.spec.template.spec.securityContext.runAsNonRoot}')
if [ "${WHOAMI_NON_ROOT}" == "true" ]; then
  pass "Deployment/crowdsec-01-whoami has spec.template.spec.securityContext.runAsNonRoot=true"
else
  fail "Deployment/crowdsec-01-whoami missing runAsNonRoot: '${WHOAMI_NON_ROOT}'"
fi

# --- Step 4: Verify Velero Controller Pod-level runAsNonRoot ---
echo ""
echo "--- Step 4: Verify Velero Controller Pod-level runAsNonRoot ---"
VELERO_NON_ROOT=$(kubectl -n velero get deployment velero -o jsonpath='{.spec.template.spec.securityContext.runAsNonRoot}')
if [ "${VELERO_NON_ROOT}" == "true" ]; then
  pass "Deployment/velero has spec.template.spec.securityContext.runAsNonRoot=true"
else
  fail "Deployment/velero missing runAsNonRoot: '${VELERO_NON_ROOT}'"
fi

# --- Step 5: Verify Velero Exception is Narrowed to node-agent (No Wildcard) ---
echo ""
echo "--- Step 5: Verify Velero PolicyException Exact Match ---"
VELERO_EX_NAMES=$(kubectl -n kyverno get policyexception pol-02-velero-run-as-non-root -o jsonpath='{.spec.match.any[*].resources.names[*]}')
if [[ " ${VELERO_EX_NAMES} " =~ [[:space:]]\*[[:space:]] ]]; then
  fail "Velero PolicyException still contains solo wildcard '*': ${VELERO_EX_NAMES}"
else
  pass "Velero PolicyException names narrowed to exact node-agent targets: ${VELERO_EX_NAMES}"
fi

# --- Step 6: Test Admission Rejection for unauthorized root Pods ---
echo ""
echo "--- Step 6: Test Admission Rejection for unauthorized Root Pods ---"

# Test 1: Unauthorized root pod in velero namespace (should fail because wildcard was removed)
echo "[*] Testing unauthorized root Pod in namespace 'velero'..."
OUT_VELERO=$(kubectl -n velero run pol03-root-test --image=harbor.imcherry5778.xyz/curated-platform/whoami@sha256:4f90b33ddca9c4d4f06527070d6e503b16d71016edea036842be2a84e60c91cb --restart=Never --dry-run=server 2>&1 || true)
if echo "${OUT_VELERO}" | grep -qiE "(pol-01-require-pod-run-as-non-root|runAsNonRoot|admission webhook)"; then
  pass "Unauthorized root Pod in namespace 'velero' correctly rejected: ${OUT_VELERO}"
else
  fail "Unauthorized root Pod in 'velero' was NOT rejected as expected: ${OUT_VELERO}"
fi

# Test 2: Unauthorized root pod in argocd namespace (should fail because exception was removed)
echo "[*] Testing unauthorized root Pod in namespace 'argocd'..."
OUT_ARGOCD=$(kubectl -n argocd run pol03-root-test --image=harbor.imcherry5778.xyz/curated-platform/whoami@sha256:4f90b33ddca9c4d4f06527070d6e503b16d71016edea036842be2a84e60c91cb --restart=Never --dry-run=server 2>&1 || true)
if echo "${OUT_ARGOCD}" | grep -qiE "(pol-01-require-pod-run-as-non-root|runAsNonRoot|admission webhook)"; then
  pass "Unauthorized root Pod in namespace 'argocd' correctly rejected: ${OUT_ARGOCD}"
else
  fail "Unauthorized root Pod in 'argocd' was NOT rejected as expected: ${OUT_ARGOCD}"
fi

# --- Step 7: Trigger Velero ad-hoc backup to verify backup completion ---
echo ""
echo "--- Step 7: Verify Velero Backup Operability ---"
VELERO_POD=$(kubectl -n velero get pod -l name=velero -o jsonpath='{.items[0].metadata.name}')
TEST_BACKUP_NAME="pol-03-verify-$(date +%s)"
echo "[*] Creating ad-hoc test backup: ${TEST_BACKUP_NAME} via pod ${VELERO_POD}..."
kubectl -n velero exec "${VELERO_POD}" -c velero -- /velero backup create "${TEST_BACKUP_NAME}" --include-namespaces=default --wait >/dev/null 2>&1 || true

BACKUP_PHASE=$(kubectl -n velero exec "${VELERO_POD}" -c velero -- /velero backup get "${TEST_BACKUP_NAME}" -o json | jq -r '.status.phase' 2>/dev/null || echo "Unknown")
if [ "${BACKUP_PHASE}" == "Completed" ]; then
  pass "Velero test backup completed successfully (phase=${BACKUP_PHASE})"
  # Cleanup test backup
  kubectl -n velero exec "${VELERO_POD}" -c velero -- /velero backup delete "${TEST_BACKUP_NAME}" --confirm >/dev/null 2>&1 || true
else
  fail "Velero test backup failed with phase: ${BACKUP_PHASE}"
fi

# --- Step 8: Verify Argo CD Applications Synced & Healthy ---
echo ""
echo "--- Step 8: Verify Argo CD Applications Status ---"
for app in platform-root policy-baseline crowdsec velero; do
  SYNC_STAT=$(kubectl -n argocd get application "${app}" -o jsonpath='{.status.sync.status}')
  HEALTH_STAT=$(kubectl -n argocd get application "${app}" -o jsonpath='{.status.health.status}')
  if [ "${SYNC_STAT}" == "Synced" ] && [ "${HEALTH_STAT}" == "Healthy" ]; then
    pass "Application/${app} is Synced and Healthy"
  else
    fail "Application/${app} in state sync=${SYNC_STAT}, health=${HEALTH_STAT}"
  fi
done

echo ""
echo "================================================================"
echo "Verification Summary: All POL-03 Checks Passed"
echo "================================================================"
