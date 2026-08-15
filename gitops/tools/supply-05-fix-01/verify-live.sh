#!/usr/bin/env bash
# SUPPLY-05-FIX-01: Live Verification Script
# Verifies supply chain convergence of AWX, CrowdSec, Velero, Renovate to curated Harbor digests,
# controller rollouts, immediate backup completion, server-side job execution, and Argo Synced/Healthy.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/k3s-01-admin.yaml}"
export KUBECONFIG

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

echo "================================================================"
echo "[SUPPLY-05-FIX-01] Live Verification: Supply Chain Convergence"
echo "================================================================"

# 1. Verify Kyverno Policy Immutability (Enforce mode & Fail policy intact)
echo -e "\n--- Step 1: Verify Policy Enforce/Fail Immutability ---"
POLICY_JSON=$(kubectl get clusterpolicy k3s-image-supply-chain-rules -o json)
FAIL_ACTION=$(echo "$POLICY_JSON" | jq -r '.spec.validationFailureAction')
FAIL_POLICY=$(echo "$POLICY_JSON" | jq -r '.spec.failurePolicy')
EXCLUDE_NS=$(echo "$POLICY_JSON" | jq -r '.spec.rules[0].exclude.any[0].resources.namespaces | sort | join(",")')

if [ "$FAIL_ACTION" == "Enforce" ] && [ "$FAIL_POLICY" == "Fail" ]; then
  pass "Policy 'k3s-image-supply-chain-rules' remains in Enforce/Fail (no relaxation)"
else
  fail "Policy is relaxed: action=${FAIL_ACTION}, policy=${FAIL_POLICY}"
fi

# Exclude namespaces must not contain user workload namespaces (awx, velero, crowdsec-01, renovate)
if echo "$EXCLUDE_NS" | grep -qv -E "^(e2e-01,falco,harbor,kube-system,kyverno,wazuh)$"; then
  fail "Unexpected namespace exclusions found: ${EXCLUDE_NS}"
else
  pass "Exact system namespace exclusions preserved: ${EXCLUDE_NS}"
fi

# 2. Verify Velero Controller & Node-Agent Rollout and Immediate Backup
echo -e "\n--- Step 2: Verify Velero Controller & Node-Agent & Backup ---"
kubectl -n velero rollout status deployment/velero --timeout=120s
kubectl -n velero rollout status daemonset/node-agent --timeout=120s

VELERO_IMG=$(kubectl -n velero get deployment velero -o jsonpath='{.spec.template.spec.containers[0].image}')
NODE_AGENT_IMG=$(kubectl -n velero get daemonset node-agent -o jsonpath='{.spec.template.spec.containers[0].image}')

if [[ "$VELERO_IMG" == harbor.imcherry5778.xyz/curated-platform/velero*@sha256:* ]] && \
   [[ "$NODE_AGENT_IMG" == harbor.imcherry5778.xyz/curated-platform/velero*@sha256:* ]]; then
  pass "Velero deployment and daemonset using curated Harbor digest: ${VELERO_IMG}"
else
  fail "Velero images not matching curated Harbor: velero=${VELERO_IMG}, node-agent=${NODE_AGENT_IMG}"
fi

# Trigger ad-hoc backup to verify backup completion
BKP_NAME="supply-05-fix-$(date +%s)"
echo "[*] Triggering ad-hoc Velero backup '${BKP_NAME}' via Backup CR..."
cat <<EOF | kubectl apply -f -
apiVersion: velero.io/v1
kind: Backup
metadata:
  name: ${BKP_NAME}
  namespace: velero
spec:
  includedNamespaces:
    - velero
  storageLocation: default
  snapshotVolumes: false
  defaultVolumesToFsBackup: false
  ttl: 1h0m0s
EOF

for _ in $(seq 1 30); do
  phase=$(kubectl get backup -n velero "${BKP_NAME}" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  if [ "$phase" == "Completed" ] || [ "$phase" == "Failed" ] || [ "$phase" == "PartiallyFailed" ]; then
    break
  fi
  sleep 2
done

BKP_PHASE=$(kubectl get backup -n velero "${BKP_NAME}" -o jsonpath='{.status.phase}')
if [ "$BKP_PHASE" == "Completed" ]; then
  pass "Ad-hoc Velero backup completed successfully (phase: ${BKP_PHASE})"
else
  fail "Velero backup failed with phase: ${BKP_PHASE}"
fi

# 3. Verify AWX Operator, Web, Task Sequential Rollout & Curated Images
echo -e "\n--- Step 3: Verify AWX Operator, Web, Task Rollout ---"
kubectl -n awx rollout status deployment/awx-operator-controller-manager --timeout=120s
kubectl -n awx rollout status deployment/awx-web --timeout=180s
kubectl -n awx rollout status deployment/awx-task --timeout=180s

AWX_OP_IMG=$(kubectl -n awx get deployment awx-operator-controller-manager -o jsonpath='{.spec.template.spec.containers[0].image}')
AWX_WEB_IMG=$(kubectl -n awx get deployment awx-web -o jsonpath='{.spec.template.spec.containers[?(@.name=="awx-web")].image}')
AWX_TASK_IMG=$(kubectl -n awx get deployment awx-task -o jsonpath='{.spec.template.spec.containers[?(@.name=="awx-task")].image}')
AWX_REDIS_IMG=$(kubectl -n awx get deployment awx-web -o jsonpath='{.spec.template.spec.containers[?(@.name=="redis")].image}')

if [[ "$AWX_OP_IMG" == harbor.imcherry5778.xyz/curated-platform/awx-operator*@sha256:* ]] && \
   [[ "$AWX_WEB_IMG" == harbor.imcherry5778.xyz/curated-platform/awx*@sha256:* ]] && \
   [[ "$AWX_TASK_IMG" == harbor.imcherry5778.xyz/curated-platform/awx*@sha256:* ]] && \
   [[ "$AWX_REDIS_IMG" == harbor.imcherry5778.xyz/curated-platform/redis*@sha256:* ]]; then
  pass "AWX operator, web, task, redis containers using curated Harbor digests"
else
  fail "AWX container images mismatch: op=${AWX_OP_IMG}, web=${AWX_WEB_IMG}, task=${AWX_TASK_IMG}, redis=${AWX_REDIS_IMG}"
fi

# 4. Verify CrowdSec 3 Deployments Rollout & Curated Images
echo -e "\n--- Step 4: Verify CrowdSec Deployments Rollout ---"
kubectl -n crowdsec-01 rollout status deployment/crowdsec-lapi --timeout=120s
kubectl -n crowdsec-01 rollout status deployment/crowdsec-agent --timeout=120s
kubectl -n crowdsec-01 rollout status deployment/crowdsec-appsec --timeout=120s

CS_LAPI_IMG=$(kubectl -n crowdsec-01 get deployment crowdsec-lapi -o jsonpath='{.spec.template.spec.containers[0].image}')
CS_AGENT_IMG=$(kubectl -n crowdsec-01 get deployment crowdsec-agent -o jsonpath='{.spec.template.spec.containers[0].image}')
CS_APPSEC_IMG=$(kubectl -n crowdsec-01 get deployment crowdsec-appsec -o jsonpath='{.spec.template.spec.containers[0].image}')

if [[ "$CS_LAPI_IMG" == harbor.imcherry5778.xyz/curated-platform/crowdsec*@sha256:* ]] && \
   [[ "$CS_AGENT_IMG" == harbor.imcherry5778.xyz/curated-platform/crowdsec*@sha256:* ]] && \
   [[ "$CS_APPSEC_IMG" == harbor.imcherry5778.xyz/curated-platform/crowdsec*@sha256:* ]]; then
  pass "CrowdSec LAPI, agent, appsec deployments using curated Harbor digest: ${CS_LAPI_IMG}"
else
  fail "CrowdSec images mismatch: lapi=${CS_LAPI_IMG}, agent=${CS_AGENT_IMG}, appsec=${CS_APPSEC_IMG}"
fi

# 5. Verify Renovate CronJob Server-Side Job Execution
echo -e "\n--- Step 5: Verify Renovate CronJob Server-Side Job Execution ---"
RENOVATE_IMG=$(kubectl -n renovate get cronjob renovate -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].image}')
if [[ "$RENOVATE_IMG" == harbor.imcherry5778.xyz/curated-platform/renovate*@sha256:* ]]; then
  pass "Renovate CronJob using curated Harbor digest: ${RENOVATE_IMG}"
else
  fail "Renovate CronJob image mismatch: ${RENOVATE_IMG}"
fi

echo "[*] Creating test job from CronJob 'renovate'..."
kubectl -n renovate delete job renovate-supply-test 2>/dev/null || true
kubectl -n renovate create job --from=cronjob/renovate renovate-supply-test
echo "[*] Waiting for test job to complete (max 60s)..."
if kubectl -n renovate wait --for=condition=complete job/renovate-supply-test --timeout=60s; then
  pass "Renovate test job successfully executed and completed"
  kubectl -n renovate delete job renovate-supply-test >/dev/null 2>&1 || true
else
  fail "Renovate test job failed or timed out"
  kubectl -n renovate get pods -n renovate -l job-name=renovate-supply-test
  kubectl -n renovate logs -n renovate -l job-name=renovate-supply-test --tail=50 || true
fi

# 6. Verify Argo CD Applications Synced & Healthy
echo -e "\n--- Step 6: Verify Argo CD Applications Health ---"
for app in velero awx crowdsec renovate; do
  sync_stat=$(kubectl -n argocd get application "$app" -o jsonpath='{.status.sync.status}')
  health_stat=$(kubectl -n argocd get application "$app" -o jsonpath='{.status.health.status}')
  if [ "$sync_stat" == "Synced" ] && [ "$health_stat" == "Healthy" ]; then
    pass "Argo CD Application '$app' is Synced and Healthy"
  else
    fail "Argo CD Application '$app' state: sync=${sync_stat}, health=${health_stat}"
  fi
done

# 7. Inventory Verification (Zero Upstream & Zero Tag-only in User Workloads)
echo -e "\n--- Step 7: Inventory & Audit Verification ---"
python3 "${REPO_ROOT}/gitops/tools/supply-02/inventory.py"

INV_JSON="${REPO_ROOT}/docs/evidence/supply-02/inventory.json"
TAG_ONLY_COUNT=$(jq -r '[.tag_only_tuples[] | select(.exception=="none")] | length' "$INV_JSON")
UPSTREAM_USER_COUNT=$(jq -r '[.live_tuples[] | select(.exception=="none" and (.registry != "harbor.imcherry5778.xyz" and (.registry | contains("ecr") | not)))] | length' "$INV_JSON")

if [ "$TAG_ONLY_COUNT" -eq 0 ]; then
  pass "Zero tag-only images in live user workloads (count: ${TAG_ONLY_COUNT})"
else
  fail "Tag-only images found in live user workloads: ${TAG_ONLY_COUNT}"
fi

if [ "$UPSTREAM_USER_COUNT" -eq 0 ]; then
  pass "Zero upstream direct images in live user workloads (count: ${UPSTREAM_USER_COUNT})"
else
  fail "Upstream direct images found in live user workloads: ${UPSTREAM_USER_COUNT}"
fi

echo "================================================================"
echo "Verification Summary: ${pass_count} Passed, ${fail_count} Failed"
echo "================================================================"

if [ "$fail_count" -gt 0 ]; then
  exit 1
fi
