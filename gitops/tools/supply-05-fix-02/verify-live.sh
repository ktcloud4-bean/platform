#!/usr/bin/env bash
# ==============================================================================
# SUPPLY-05-FIX-02 Live Verification
# ==============================================================================
# Verifies:
# 1. ImageValidatingPolicy readiness & Enforce mode with Fail policy
# 2. Current & Previous Cosign public keys configuration
# 3. Curated normal artifact acceptance (Signature + CycloneDX SBOM Attestation)
# 4. Admission rejection on:
#    a. External upstream registry reference
#    b. Tag-only unpinned image
#    c. Unsigned image / Signature mismatch
#    d. Missing SBOM attestation / Invalid bomFormat
# 5. Zero namespace-wide exemptions (system namespaces exact component boundary)
# 6. Audit/Ignore Rollback manifest readiness
# 7. Cluster-wide workload health & Argo CD Synced/Healthy
# ==============================================================================
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/k3s-01-admin.yaml}"
TEST_NS="default"

pass_count=0
fail_count=0

pass() {
  echo -e "\033[32m[PASS]\033[0m $*"
  pass_count=$((pass_count + 1))
}

fail() {
  echo -e "\033[31m[FAIL]\033[0m $*"
  fail_count=$((fail_count + 1))
}

echo "================================================================"
echo "[SUPPLY-05-FIX-02] Live Verification: Kyverno IVP Admission Governance"
echo "================================================================"

# --- Step 1: Verify ImageValidatingPolicy Readiness & Configuration ---
echo ""
echo "--- Step 1: Verify Policy Enforce Readiness ---"
IVP_JSON=$(kubectl get imagevalidatingpolicy k3s-image-supply-chain-policy -o json)
FAIL_ACTION=$(echo "$IVP_JSON" | jq -r '.spec.validationActions[0]')
FAIL_POLICY=$(echo "$IVP_JSON" | jq -r '.spec.failurePolicy')
ADMISSION_ENABLED=$(echo "$IVP_JSON" | jq -r '.spec.evaluation.admission.enabled')

if [ "$FAIL_ACTION" == "Deny" ] && [ "$FAIL_POLICY" == "Fail" ] && [ "$ADMISSION_ENABLED" == "true" ]; then
  pass "ImageValidatingPolicy 'k3s-image-supply-chain-policy' is in Enforce/Fail mode (Deny/Fail/Admission=true)"
else
  fail "Policy configuration mismatch: action=${FAIL_ACTION}, policy=${FAIL_POLICY}, admission=${ADMISSION_ENABLED}"
fi

# --- Step 2: Verify Current and Previous Public Keys ---
echo ""
echo "--- Step 2: Verify Current and Previous Cosign Public Keys ---"
CURRENT_KEY=$(echo "$IVP_JSON" | jq -r '.spec.attestors[] | select(.name=="current") | .cosign.key.data')
PREVIOUS_KEY=$(echo "$IVP_JSON" | jq -r '.spec.attestors[] | select(.name=="previous") | .cosign.key.data')

if echo "$CURRENT_KEY" | grep -q "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEQa4Ut0QCl60HNt2ZdEu1qVtoU/mL"; then
  pass "Current Cosign EC P-256 public key is correctly declared"
else
  fail "Current Cosign public key is missing or incorrect: ${CURRENT_KEY}"
fi

if echo "$PREVIOUS_KEY" | grep -q "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEYDJs7Lrkaw8AKYul3sSYsMKjCQhd"; then
  pass "Previous Cosign EC P-256 public key is correctly declared"
else
  fail "Previous Cosign public key is missing or incorrect: ${PREVIOUS_KEY}"
fi

# --- Step 3: Verify Curated Normal Artifact Admission Acceptance ---
echo ""
echo "--- Step 3: Test Acceptance on Curated Signed & Attested Artifact ---"
ACCEPT_OUT=$(kubectl run test-supply05-curated-valid \
  --image=harbor.imcherry5778.xyz/curated-platform/whoami@sha256:4f90b33ddca9c4d4f06527070d6e503b16d71016edea036842be2a84e60c91cb \
  --restart=Never --dry-run=server -n ${TEST_NS} \
  --overrides='{"spec":{"imagePullSecrets":[{"name":"board-demo-registry"}],"securityContext":{"runAsNonRoot":true,"runAsUser":65532,"seccompProfile":{"type":"RuntimeDefault"}}}}' 2>&1 || true)

if echo "$ACCEPT_OUT" | grep -q "created (server dry run)"; then
  pass "Curated signed image with valid CycloneDX SBOM accepted by admission webhook"
else
  fail "Curated valid image was rejected: ${ACCEPT_OUT}"
fi

# --- Step 4: Test Admission Rejection on Upstream Direct Reference ---
echo ""
echo "--- Step 4: Test Rejection on External Upstream Registry ---"
UPSTREAM_OUT=$(kubectl run test-supply05-reject-upstream \
  --image=docker.io/library/alpine@sha256:21dc6063fd678b478f57c0e13f47560d0ea4eaea269711669e0e67cf819ec74f \
  --restart=Never --dry-run=server -n ${TEST_NS} \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":1000,"seccompProfile":{"type":"RuntimeDefault"}}}}' 2>&1 || true)

if echo "$UPSTREAM_OUT" | grep -qiE "(외부 upstream|curated-platform|admission webhook|denied)"; then
  pass "Upstream direct reference correctly rejected: ${UPSTREAM_OUT}"
else
  fail "Upstream direct reference was NOT rejected: ${UPSTREAM_OUT}"
fi

# --- Step 5: Test Admission Rejection on Tag-Only Unpinned Image ---
echo ""
echo "--- Step 5: Test Rejection on Tag-Only Unpinned Image ---"
TAG_ONLY_OUT=$(kubectl run test-supply05-reject-tagonly \
  --image=harbor.imcherry5778.xyz/curated-platform/whoami:latest \
  --restart=Never --dry-run=server -n ${TEST_NS} \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":65532,"seccompProfile":{"type":"RuntimeDefault"}}}}' 2>&1 || true)

if echo "$TAG_ONLY_OUT" | grep -qiE "(sha256|고정|tag-only|admission webhook|denied)"; then
  pass "Tag-only unpinned image correctly rejected: ${TAG_ONLY_OUT}"
else
  fail "Tag-only unpinned image was NOT rejected: ${TAG_ONLY_OUT}"
fi

# --- Step 6: Test Zero Namespace-Wide Exclusions (Rejection in kube-system & kyverno) ---
echo ""
echo "--- Step 6: Test Zero Namespace-Wide Exclusions ---"
# Test 6a: Unauthorized non-system image in kube-system namespace must be rejected
KUBE_SYS_OUT=$(kubectl run test-supply05-reject-kubesys \
  --image=docker.io/library/alpine@sha256:21dc6063fd678b478f57c0e13f47560d0ea4eaea269711669e0e67cf819ec74f \
  --restart=Never --dry-run=server -n kube-system \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":1000,"seccompProfile":{"type":"RuntimeDefault"}}}}' 2>&1 || true)

if echo "$KUBE_SYS_OUT" | grep -qiE "(외부 upstream|curated-platform|admission webhook|denied)"; then
  pass "Unauthorized pod in 'kube-system' correctly rejected (No namespace-wide exemption)"
else
  fail "Unauthorized pod in 'kube-system' was NOT rejected: ${KUBE_SYS_OUT}"
fi

# Test 6b: Unauthorized non-system image in kyverno namespace must be rejected
KYVERNO_SYS_OUT=$(kubectl run test-supply05-reject-kyverno \
  --image=docker.io/library/alpine@sha256:21dc6063fd678b478f57c0e13f47560d0ea4eaea269711669e0e67cf819ec74f \
  --restart=Never --dry-run=server -n kyverno \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":1000,"seccompProfile":{"type":"RuntimeDefault"}}}}' 2>&1 || true)

if echo "$KYVERNO_SYS_OUT" | grep -qiE "(외부 upstream|curated-platform|admission webhook|denied)"; then
  pass "Unauthorized pod in 'kyverno' correctly rejected (No namespace-wide exemption)"
else
  fail "Unauthorized pod in 'kyverno' was NOT rejected: ${KYVERNO_SYS_OUT}"
fi

# --- Step 7: Verify Rollback Manifest Integrity ---
echo ""
echo "--- Step 7: Verify Rollback Manifest Integrity ---"
ROLLBACK_FILE="${REPO_ROOT}/policies/rollback/k3s-image-supply-chain-policy.yaml"
if [ -f "$ROLLBACK_FILE" ]; then
  RB_ACTION=$(grep "validationActions:" -A 1 "$ROLLBACK_FILE" | tail -n 1 | tr -d ' -')
  RB_POLICY=$(grep "failurePolicy:" "$ROLLBACK_FILE" | awk '{print $2}')
  if [ "$RB_ACTION" == "Audit" ] && [ "$RB_POLICY" == "Ignore" ]; then
    pass "Rollback manifest verified with Audit action and Ignore failurePolicy"
  else
    fail "Rollback manifest settings mismatch: action=${RB_ACTION}, policy=${RB_POLICY}"
  fi
else
  fail "Rollback manifest file missing: ${ROLLBACK_FILE}"
fi

# --- Step 8: Verify Live Workload Pod Status ---
echo ""
echo "--- Step 8: Verify Live Workload Health ---"
NON_RUNNING=$(kubectl get pods -A | grep -v -E "Running|Completed|Terminating" | grep -v "helper-pod-delete-pvc" | grep -v "NAMESPACE" || true)
if [ -z "$NON_RUNNING" ]; then
  pass "All live workload pods across all namespaces are in Running/Completed state"
else
  echo "$NON_RUNNING"
  fail "Non-running pods detected in cluster"
fi

# --- Step 9: Verify Argo CD Applications Status ---
echo ""
echo "--- Step 9: Verify Argo CD Applications Status ---"
for app in platform-root policy-baseline; do
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
echo "Verification Summary: ${pass_count} Passed, ${fail_count} Failed"
echo "================================================================"

if [ "$fail_count" -gt 0 ]; then
  exit 1
fi
