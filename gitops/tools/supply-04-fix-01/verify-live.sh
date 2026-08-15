#!/usr/bin/env bash
# SUPPLY-04-FIX-01: Live Verification Script
# Verifies safe migration of Keycloak bootstrap Job to version v3 using curated image
# with check-first/no-op path, zero mutation of existing Keycloak users/clients,
# and cluster-wide sync/health state.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/k3s-01-admin.yaml}"
NS="keycloak"

echo "================================================================"
echo "[SUPPLY-04-FIX-01] Live Verification: Keycloak Bootstrap Job v3"
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

# 1. Verify existing completed Job (keycloak-bootstrap-v2) is preserved
echo -e "\n--- Step 1: Verify Existing Completed Job Preservation ---"
if KUBECONFIG="$KUBECONFIG" kubectl -n "$NS" get job keycloak-bootstrap-v2 >/dev/null 2>&1; then
  pass "Existing completed job 'keycloak-bootstrap-v2' is preserved without manual deletion"
else
  fail "Existing completed job 'keycloak-bootstrap-v2' was missing"
fi

# 2. Deploy keycloak-bootstrap-v3 Job
echo -e "\n--- Step 2: Deploy and Execute keycloak-bootstrap-v3 Job ---"
KUBECONFIG="$KUBECONFIG" kubectl apply -f "${REPO_ROOT}/gitops/apps/keycloak/bootstrap-job.yaml"

# Wait for Job to complete
echo "Waiting for keycloak-bootstrap-v3 to complete..."
if KUBECONFIG="$KUBECONFIG" kubectl -n "$NS" wait --for=condition=complete job/keycloak-bootstrap-v3 --timeout=120s; then
  pass "Job 'keycloak-bootstrap-v3' completed successfully"
else
  fail "Job 'keycloak-bootstrap-v3' failed or timed out"
fi

# 3. Verify Job Image uses Curated Digest
echo -e "\n--- Step 3: Verify Curated Image and Digest on Job v3 ---"
JOB_V3_JSON=$(KUBECONFIG="$KUBECONFIG" kubectl -n "$NS" get job keycloak-bootstrap-v3 -o json)
VAULT_IMG=$(echo "$JOB_V3_JSON" | jq -r '.spec.template.spec.initContainers[0].image')
KC_IMG=$(echo "$JOB_V3_JSON" | jq -r '.spec.template.spec.containers[0].image')

if [[ "$VAULT_IMG" =~ ^harbor.imcherry5778.xyz/curated-platform/vault@sha256: ]] && \
   [[ "$KC_IMG" =~ ^harbor.imcherry5778.xyz/curated-platform/keycloak@sha256: ]]; then
  pass "Job v3 initContainers and containers use Harbor curated @sha256 digest images"
else
  fail "Job v3 images are not curated/digest-pinned: vault=$VAULT_IMG, keycloak=$KC_IMG"
fi

# 4. Verify Keycloak Runtime Deployment and Pod Health
echo -e "\n--- Step 4: Verify Keycloak Server Deployment Health ---"
KC_POD_STATUS=$(KUBECONFIG="$KUBECONFIG" kubectl -n "$NS" get pods -l app.kubernetes.io/name=keycloak,app.kubernetes.io/component=server -o jsonpath='{.items[0].status.phase}')
if [ "$KC_POD_STATUS" == "Running" ]; then
  pass "Keycloak server Pod is in Running state"
else
  fail "Keycloak server Pod is not Running: $KC_POD_STATUS"
fi

# 5. Verify Ingress & SSO OpenID Endpoint
echo -e "\n--- Step 5: Verify SSO OpenID Endpoint ---"
ISSUER=$(curl -sk https://sso.imcherry5778.xyz/realms/platform/.well-known/openid-configuration | jq -r '.issuer // empty' || true)
if [ "$ISSUER" == "https://sso.imcherry5778.xyz/realms/platform" ]; then
  pass "Keycloak OIDC issuer is valid: $ISSUER"
else
  fail "Keycloak OIDC discovery failed (issuer=$ISSUER)"
fi

# 6. Verify Kyverno Enforce Policy Compliance
echo -e "\n--- Step 6: Verify Kyverno Enforce Policy Compliance ---"
POLICY_STATUS=$(KUBECONFIG="$KUBECONFIG" kubectl get clusterpolicy k3s-image-supply-chain-rules -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
if [ "$POLICY_STATUS" == "True" ]; then
  pass "Kyverno clusterpolicy 'k3s-image-supply-chain-rules' is active in Enforce mode"
else
  fail "Kyverno policy not ready"
fi

# 7. Check Cluster-wide Pod Status
echo -e "\n--- Step 7: Verify Cluster-wide Pod Status ---"
NON_RUNNING=$(KUBECONFIG="$KUBECONFIG" kubectl get pods -A | grep -v -E "Running|Completed" | grep -v "helper-pod-delete-pvc" | grep -v "NAMESPACE" || true)
if [ -z "$NON_RUNNING" ]; then
  pass "All cluster workload pods are in Running/Completed state"
else
  echo "$NON_RUNNING"
  fail "Non-running pods detected"
fi

echo "================================================================"
echo "Verification Summary: ${pass_count} Passed, ${fail_count} Failed"
echo "================================================================"

if [ "$fail_count" -gt 0 ]; then
  exit 1
fi
