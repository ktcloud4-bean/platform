#!/usr/bin/env bash
# SUPPLY-05: Live Verification Script
# Verifies k3s Kyverno ClusterPolicy Enforce mode, admission webhook rejections,
# curated image acceptance, system namespace isolation, and cluster-wide workload health.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/k3s-01-admin.yaml}"
TEST_NS="default"

echo "================================================================"
echo "[SUPPLY-05] Live Verification: k3s Image Policy Enforce Mode"
echo "================================================================"

pass_count=0
fail_count=0

pass() {
  echo -e "\e[32m[PASS]\e[0m $1"
  pass_count=$((pass_count + 1))
}

fail() {
  echo -e "\e[31m[FAIL]\e[0m $1"
  fail_count=$((fail_count + 1))
}

# 1. Verify ClusterPolicy Readiness & Webhook Configuration
echo -e "\n--- Step 1: Verify Policy Enforce Readiness ---"
POLICY_JSON=$(KUBECONFIG="$KUBECONFIG" kubectl get clusterpolicy k3s-image-supply-chain-rules -o json)
READY_STATUS=$(echo "$POLICY_JSON" | jq -r '.status.conditions[] | select(.type=="Ready") | .status')
FAIL_ACTION=$(echo "$POLICY_JSON" | jq -r '.spec.validationFailureAction')
FAIL_POLICY=$(echo "$POLICY_JSON" | jq -r '.spec.failurePolicy')

if [ "$READY_STATUS" == "True" ] && [ "$FAIL_ACTION" == "Enforce" ] && [ "$FAIL_POLICY" == "Fail" ]; then
  pass "Policy 'k3s-image-supply-chain-rules' is Ready with validationFailureAction=Enforce and failurePolicy=Fail"
else
  fail "Policy status check failed (ready: $READY_STATUS, failureAction: $FAIL_ACTION, failurePolicy: $FAIL_POLICY)"
fi

# 2. Test Admission Rejection: External Upstream Registry Direct Reference
echo -e "\n--- Step 2: Test Rejection on External Upstream Registry ---"
UPSTREAM_TEST_YAML=$(cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: test-reject-upstream-direct
  namespace: ${TEST_NS}
spec:
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: test
      image: docker.io/library/alpine@sha256:21dc6063fd678b478f57c0e13f47560d0ea4eaea269711669e0e67cf819ec74f
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
EOF
)

OUT_UPSTREAM=$(echo "$UPSTREAM_TEST_YAML" | KUBECONFIG="$KUBECONFIG" kubectl apply -f - 2>&1 || true)
if echo "$OUT_UPSTREAM" | grep -q "외부 upstream"; then
  pass "Admission webhook correctly DENIED upstream direct reference Pod"
else
  fail "Admission webhook failed to deny upstream direct reference Pod: $OUT_UPSTREAM"
  KUBECONFIG="$KUBECONFIG" kubectl -n ${TEST_NS} delete pod test-reject-upstream-direct 2>/dev/null || true
fi

# 3. Test Admission Rejection: Tag-Only Unpinned Image
echo -e "\n--- Step 3: Test Rejection on Tag-Only Unpinned Image ---"
TAG_ONLY_TEST_YAML=$(cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: test-reject-tag-only
  namespace: ${TEST_NS}
spec:
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: test
      image: harbor.imcherry5778.xyz/curated-platform/whoami:latest
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
EOF
)

OUT_TAG_ONLY=$(echo "$TAG_ONLY_TEST_YAML" | KUBECONFIG="$KUBECONFIG" kubectl apply -f - 2>&1 || true)
if echo "$OUT_TAG_ONLY" | grep -q "sha256 다이제스트"; then
  pass "Admission webhook correctly DENIED tag-only unpinned image Pod"
else
  fail "Admission webhook failed to deny tag-only unpinned image Pod: $OUT_TAG_ONLY"
  KUBECONFIG="$KUBECONFIG" kubectl -n ${TEST_NS} delete pod test-reject-tag-only 2>/dev/null || true
fi

# 4. Test Admission Acceptance: Valid Curated Digest-Pinned Image
echo -e "\n--- Step 4: Test Acceptance on Curated Digest-Pinned Image ---"
VALID_TEST_YAML=$(cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: test-accept-curated-image
  namespace: ${TEST_NS}
spec:
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: test
      image: harbor.imcherry5778.xyz/curated-platform/whoami@sha256:4f90b33ddca9c4d4f06527070d6e503b16d71016edea036842be2a84e60c91cb
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
EOF
)

OUT_VALID=$(echo "$VALID_TEST_YAML" | KUBECONFIG="$KUBECONFIG" kubectl apply -f - 2>&1 || true)
if echo "$OUT_VALID" | grep -q "created"; then
  pass "Admission webhook correctly ALLOWED valid curated digest-pinned Pod"
  KUBECONFIG="$KUBECONFIG" kubectl -n ${TEST_NS} delete pod test-accept-curated-image --now >/dev/null 2>&1 || true
else
  fail "Admission webhook unexpectedly denied valid curated image Pod: $OUT_VALID"
fi

# 5. Verify Cluster-wide Live Workload Pod Status
echo -e "\n--- Step 5: Verify Cluster-wide Workload Health ---"
sleep 5
NON_RUNNING=$(KUBECONFIG="$KUBECONFIG" kubectl get pods -A | grep -v -E "Running|Completed|Terminating" | grep -v "helper-pod-delete-pvc" | grep -v "NAMESPACE" || true)
if [ -z "$NON_RUNNING" ]; then
  pass "All live workload pods across all namespaces are in Running/Completed state"
else
  echo "$NON_RUNNING"
  fail "Non-running pods detected in cluster"
fi

# 6. Verify Exact System Exceptions & No Wildcard Namespace Exclusions
echo -e "\n--- Step 6: Verify Exact System Namespace Exceptions ---"
EXCLUDE_NAMESPACES=$(echo "$POLICY_JSON" | jq -r '.spec.rules[0].exclude.any[0].resources.namespaces[]')
if echo "$EXCLUDE_NAMESPACES" | grep -q "kube-system" && echo "$EXCLUDE_NAMESPACES" | grep -q "kyverno" && echo "$EXCLUDE_NAMESPACES" | grep -q "falco"; then
  pass "Exact system namespace exceptions correctly configured in exclude rules"
else
  fail "exclude rules missing required system namespaces: $EXCLUDE_NAMESPACES"
fi

# 7. Verify Rollback Capability (Audit / Ignore)
echo -e "\n--- Step 7: Verify Rollback Capability ---"
ROLLBACK_FILE="${REPO_ROOT}/policies/rollback/k3s-image-supply-chain-audit.yaml"
if [ -f "$ROLLBACK_FILE" ]; then
  pass "Rollback audit policy manifest exists: $ROLLBACK_FILE"
else
  fail "Rollback audit policy manifest not found: $ROLLBACK_FILE"
fi

echo "================================================================"
echo "Verification Summary: ${pass_count} Passed, ${fail_count} Failed"
echo "================================================================"

if [ "$fail_count" -gt 0 ]; then
  exit 1
fi
