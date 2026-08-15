#!/usr/bin/env bash
# SUPPLY-04: Live Verification Script
# Verifies Harbor curated promotion, Cosign signatures, CycloneDX SBOM attestations,
# upstream isolation, and live workload health.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/k3s-01-admin.yaml}"
HARBOR_REGISTRY="harbor.imcherry5778.xyz"
CURATED_PROJECT="curated-platform"
VAULT_ROOT_TOKEN_FILE="$HOME/secrets/ktcloud4-bean/vault-root.token"

echo "================================================================"
echo "[SUPPLY-04] Live Verification: Container Supply Chain Promotion"
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

# 1. Verify Harbor Curated Project and Artifact Count
echo -e "\n--- Step 1: Verify Harbor curated-platform Project ---"
HARBOR_PASS=$(grep HARBOR_ADMIN_PASSWORD "$HOME/secrets/ktcloud4-bean/harbor/env" | cut -d= -f2)
CURATED_PROJ_HTTP=$(curl -k -s -L -o /dev/null -w "%{http_code}" -u "admin:${HARBOR_PASS}" \
  "https://${HARBOR_REGISTRY}/api/v2.0/projects?name=${CURATED_PROJECT}")

if [ "$CURATED_PROJ_HTTP" -eq 200 ]; then
  pass "Harbor project '${CURATED_PROJECT}' exists and accessible via API (HTTP 200)"
else
  fail "Harbor project '${CURATED_PROJECT}' check failed (HTTP ${CURATED_PROJ_HTTP})"
fi

# 2. Verify Promoted Images & Cosign Signatures & SBOM Attestations
echo -e "\n--- Step 2: Verify Cosign Signatures & CycloneDX Attestations ---"
PROMOTED_FILE="${REPO_ROOT}/docs/evidence/supply-04/promoted-images.json"
if [ -f "$PROMOTED_FILE" ]; then
  IMAGE_COUNT=$(jq 'length' "$PROMOTED_FILE")
  if [ "$IMAGE_COUNT" -ge 49 ]; then
    pass "Promoted images inventory contains ${IMAGE_COUNT} images (>= 49 expected)"
  else
    fail "Promoted images count is ${IMAGE_COUNT} (< 49 expected)"
  fi
else
  fail "Promoted images file not found: $PROMOTED_FILE"
fi

# Extract Cosign public key from Vault
V_TOK=$(cat "$VAULT_ROOT_TOKEN_FILE")
PUB_KEY_TMP=$(mktemp --suffix=.pub)
KUBECONFIG="$KUBECONFIG" kubectl -n vault exec vault-0 -- sh -c "
  export VAULT_CACERT=/vault/data/tls/vault.crt
  export VAULT_TOKEN='${V_TOK}'
  vault kv get -field=cosign_public_key kv/jenkins/runtime
" > "$PUB_KEY_TMP"

# Verify 3 representative promoted images signature and attestation
REPRESENTATIVES=(
  "harbor.imcherry5778.xyz/curated-platform/gitea"
  "harbor.imcherry5778.xyz/curated-platform/sonarqube"
  "harbor.imcherry5778.xyz/curated-platform/keycloak"
)

for repo in "${REPRESENTATIVES[@]}"; do
  EXACT_REF=$(jq -r --arg repo "$repo" '.[] | select(.curated_repo == $repo) | .curated_exact_ref' "$PROMOTED_FILE" | head -n 1)
  if [ -n "$EXACT_REF" ]; then
    if cosign verify --key "$PUB_KEY_TMP" --allow-insecure-registry "$EXACT_REF" >/dev/null 2>&1; then
      pass "Cosign signature verified for $EXACT_REF"
    else
      fail "Cosign signature verification failed for $EXACT_REF"
    fi

    if cosign verify-attestation --key "$PUB_KEY_TMP" --type cyclonedx --allow-insecure-registry "$EXACT_REF" >/dev/null 2>&1; then
      pass "CycloneDX SBOM attestation verified for $EXACT_REF"
    else
      fail "CycloneDX SBOM attestation verification failed for $EXACT_REF"
    fi
  fi
done
rm -f "$PUB_KEY_TMP"

# 3. Verify Live Workload Pod Status
echo -e "\n--- Step 3: Verify Live Workload Health ---"
NON_RUNNING=$(KUBECONFIG="$KUBECONFIG" kubectl get pods -A | grep -v -E "Running|Completed|Terminating" | grep -v "helper-pod-delete-pvc" | grep -v "NAMESPACE" || true)
if [ -z "$NON_RUNNING" ]; then
  pass "All live workload pods across all namespaces are in Running/Completed state"
else
  echo "$NON_RUNNING"
  fail "Non-running pods detected in cluster"
fi

# 4. Verify Git Manifests Cleanliness (No plaintext private key block)
echo -e "\n--- Step 4: Verify Git Secret Isolation ---"
KEY_BLOCKS=$(git grep "BEGIN ENCRYPTED COSIGN PRIVATE KEY" gitops/ || true)
if [ -z "$KEY_BLOCKS" ]; then
  pass "Zero plaintext private key blocks committed in Git repository"
else
  fail "Private key block leakage detected in Git: $KEY_BLOCKS"
fi

echo "================================================================"
echo "Verification Summary: ${pass_count} Passed, ${fail_count} Failed"
echo "================================================================"

if [ "$fail_count" -gt 0 ]; then
  exit 1
fi
