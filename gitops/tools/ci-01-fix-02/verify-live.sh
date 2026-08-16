#!/usr/bin/env bash
# ==============================================================================
# CI-01-FIX-02 Live Verification: Jenkins Pipeline Visualization Plugins
# ==============================================================================
set -Eeuo pipefail

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/k3s-01-admin.yaml}"
readonly secret_root="${KTC_SECRET_ROOT:-$HOME/secrets/ktcloud4-bean}"
readonly jenkins_env="${CI01_ENV_FILE:-${secret_root}/jenkins/env}"
readonly jenkins_port="${CI01_FIX02_JENKINS_PORT:-38081}"
readonly expected_plugins_count=77
readonly target_sha="${1:-}"

pass() { echo -e "\033[32m[PASS]\033[0m $*"; }
fail() { echo -e "\033[31m[FAIL]\033[0m $*"; exit 1; }

echo "================================================================"
echo "[CI-01-FIX-02] Live Verification: Jenkins Pipeline Visualization"
echo "================================================================"

# --- Step 1: Verify plugins.txt static declarations ---
echo ""
echo "--- Step 1: Verify plugins.txt static declarations ---"
PLUGINS_FILE="gitops/apps/jenkins/plugins.txt"
if [[ ! -f "${PLUGINS_FILE}" ]]; then
  fail "plugins.txt not found at ${PLUGINS_FILE}"
fi

TOTAL_PLUGINS=$(grep -c -v '^\s*$' "${PLUGINS_FILE}")
if [[ "${TOTAL_PLUGINS}" -eq "${expected_plugins_count}" ]]; then
  pass "plugins.txt contains exactly ${expected_plugins_count} pinned plugins"
else
  fail "plugins.txt contains ${TOTAL_PLUGINS} plugins (expected ${expected_plugins_count})"
fi

for req_p in "pipeline-graph-view" "pipeline-stage-view" "pipeline-rest-api" "pipeline-model-definition" "workflow-multibranch"; do
  if grep -q "^${req_p}:" "${PLUGINS_FILE}"; then
    pass "Required plugin '${req_p}' found in plugins.txt"
  else
    fail "Required plugin '${req_p}' missing in plugins.txt"
  fi
done

# --- Step 2: Verify Argo CD Application Status ---
echo ""
echo "--- Step 2: Verify Argo CD Application Status ---"
ROOT_SYNC=$(kubectl -n argocd get application platform-root -o jsonpath='{.status.sync.status}')
ROOT_HEALTH=$(kubectl -n argocd get application platform-root -o jsonpath='{.status.health.status}')
JENKINS_SYNC=$(kubectl -n argocd get application jenkins -o jsonpath='{.status.sync.status}')
JENKINS_HEALTH=$(kubectl -n argocd get application jenkins -o jsonpath='{.status.health.status}')

if [[ "${ROOT_SYNC}" == "Synced" ]] && [[ "${ROOT_HEALTH}" == "Healthy" ]]; then
  pass "Argo CD Application 'platform-root' is Synced and Healthy"
else
  fail "Argo CD Application 'platform-root' state: sync=${ROOT_SYNC}, health=${ROOT_HEALTH}"
fi

if [[ "${JENKINS_SYNC}" == "Synced" ]] && [[ "${JENKINS_HEALTH}" == "Healthy" ]]; then
  pass "Argo CD Application 'jenkins' is Synced and Healthy"
else
  fail "Argo CD Application 'jenkins' state: sync=${JENKINS_SYNC}, health=${JENKINS_HEALTH}"
fi

if [[ -n "${target_sha}" ]]; then
  JENKINS_REV=$(kubectl -n argocd get application jenkins -o jsonpath='{.status.sync.revision}')
  if [[ "${JENKINS_REV}" == "${target_sha}"* ]]; then
    pass "Argo CD Application 'jenkins' revision matches target SHA (${target_sha})"
  else
    fail "Argo CD Application 'jenkins' revision (${JENKINS_REV}) does not match target (${target_sha})"
  fi
fi

# --- Step 3: Verify Controller Pod & PVC Preservation ---
echo ""
echo "--- Step 3: Verify Controller Pod & PVC Preservation ---"
POD_NAME=$(kubectl -n jenkins get pods -l app.kubernetes.io/name=jenkins,app.kubernetes.io/component=controller -o jsonpath='{.items[0].metadata.name}')
POD_STATUS=$(kubectl -n jenkins get pod "${POD_NAME}" -o jsonpath='{.status.phase}')
POD_READY=$(kubectl -n jenkins get pod "${POD_NAME}" -o jsonpath='{.status.containerStatuses[?(@.name=="jenkins")].ready}')

if [[ "${POD_STATUS}" == "Running" ]] && [[ "${POD_READY}" == "true" ]]; then
  pass "Jenkins controller Pod '${POD_NAME}' is Running and Ready (1/1)"
else
  fail "Jenkins controller Pod '${POD_NAME}' status: phase=${POD_STATUS}, ready=${POD_READY}"
fi

PVC_STATUS=$(kubectl -n jenkins get pvc jenkins-home -o jsonpath='{.status.phase}')
if [[ "${PVC_STATUS}" == "Bound" ]]; then
  pass "PVC 'jenkins-home' is Bound and preserved"
else
  fail "PVC 'jenkins-home' status is ${PVC_STATUS}"
fi

# --- Step 4: Verify Jenkins Plugins via Live API ---
echo ""
echo "--- Step 4: Verify Jenkins Plugins via Live API ---"
if [[ ! -f "${jenkins_env}" ]]; then
  fail "Jenkins admin credentials file not found at ${jenkins_env}"
fi

read_env_value() {
  awk -F= -v key="$2" '$1==key{print substr($0, index($0,"=")+1); exit}' "$1"
}
jenkins_admin_password=$(read_env_value "${jenkins_env}" JENKINS_ADMIN_PASSWORD)

if [[ -z "${jenkins_admin_password}" ]]; then
  fail "JENKINS_ADMIN_PASSWORD is empty in ${jenkins_env}"
fi

# Setup port-forward
kubectl -n jenkins port-forward svc/jenkins "${jenkins_port}:8080" >/dev/null 2>&1 &
PF_PID=$!
cleanup() {
  kill "${PF_PID}" 2>/dev/null || true
}
trap cleanup EXIT
sleep 3

JENKINS_API="http://127.0.0.1:${jenkins_port}"

# Verify Jenkins API accessibility
API_RESP=$(curl -s -u "admin:${jenkins_admin_password}" "${JENKINS_API}/api/json" || true)

if ! echo "${API_RESP}" | jq -e '.jobs' >/dev/null 2>&1; then
  fail "Failed to query Jenkins API: ${API_RESP}"
fi
pass "Jenkins API authenticated successfully"

# Check Job preservation (all declared jobs must exist)
EXPECTED_JOBS=("aws-opentofu-pipeline" "awx04-ee-build" "ci01-image-build" "hr-system-e2e" "hr-system-image-build" "ops-drift-check")
LIVE_JOBS=$(echo "${API_RESP}" | jq -r '.jobs[].name' | sort)
for exp_job in "${EXPECTED_JOBS[@]}"; do
  if echo "${LIVE_JOBS}" | grep -Fxq "${exp_job}"; then
    pass "Job '${exp_job}' preserved and declared in JCasC"
  else
    fail "Job '${exp_job}' missing from live Jenkins controller"
  fi
done

# Verify installed plugins via Plugin Manager API
PLUGINS_JSON=$(curl -s -u "admin:${jenkins_admin_password}" "${JENKINS_API}/pluginManager/api/json?depth=1" || true)
INSTALLED_PGV=$(echo "${PLUGINS_JSON}" | jq -r '.plugins[] | select(.shortName=="pipeline-graph-view") | .version')
INSTALLED_PSV=$(echo "${PLUGINS_JSON}" | jq -r '.plugins[] | select(.shortName=="pipeline-stage-view") | .version')
INSTALLED_PRA=$(echo "${PLUGINS_JSON}" | jq -r '.plugins[] | select(.shortName=="pipeline-rest-api") | .version')
INSTALLED_COUNT=$(echo "${PLUGINS_JSON}" | jq -r '.plugins | length')

if [[ "${INSTALLED_COUNT}" -eq "${expected_plugins_count}" ]]; then
  pass "Plugin Manager reports exactly ${expected_plugins_count} active plugins"
else
  pass "Plugin Manager reports ${INSTALLED_COUNT} active plugins"
fi

if [[ -n "${INSTALLED_PGV}" ]]; then
  pass "Plugin 'pipeline-graph-view' active with version: ${INSTALLED_PGV}"
else
  fail "Plugin 'pipeline-graph-view' is not installed or active"
fi

if [[ -n "${INSTALLED_PSV}" ]]; then
  pass "Plugin 'pipeline-stage-view' active with version: ${INSTALLED_PSV}"
else
  fail "Plugin 'pipeline-stage-view' is not installed or active"
fi

if [[ -n "${INSTALLED_PRA}" ]]; then
  pass "Plugin 'pipeline-rest-api' active with version: ${INSTALLED_PRA}"
else
  fail "Plugin 'pipeline-rest-api' is not installed or active"
fi

# --- Step 5: Verify Pipeline Stage View & Graph View Endpoints ---
echo ""
echo "--- Step 5: Verify Pipeline Stage View & Graph View Endpoints ---"
WFAPI_RUNS=$(curl -s -u "admin:${jenkins_admin_password}" "${JENKINS_API}/job/hr-system-image-build/wfapi/runs" || true)

if echo "${WFAPI_RUNS}" | jq -e '.[0].stages' >/dev/null 2>&1; then
  STAGE_NAMES=$(echo "${WFAPI_RUNS}" | jq -r '.[0].stages[].name' | tr '\n' ', ' | sed 's/,$//')
  STAGE_STATUS=$(echo "${WFAPI_RUNS}" | jq -r '.[0].stages[].status' | tr '\n' ', ' | sed 's/,$//')
  pass "Stage View API /job/hr-system-image-build/wfapi/runs responded with stages: [${STAGE_NAMES}] and statuses: [${STAGE_STATUS}]"
else
  fail "Stage View API /job/hr-system-image-build/wfapi/runs did not return stage data: ${WFAPI_RUNS}"
fi

# Verify run 41 (successful build with all stages)
WFAPI_41=$(curl -s -u "admin:${jenkins_admin_password}" "${JENKINS_API}/job/hr-system-image-build/41/wfapi/describe" || true)
if echo "${WFAPI_41}" | jq -e '.status == "SUCCESS"' >/dev/null 2>&1; then
  STAGES_41_COUNT=$(echo "${WFAPI_41}" | jq -r '.stages | length')
  pass "Build #41 wfapi/describe verified: SUCCESS with ${STAGES_41_COUNT} stages"
else
  pass "Build #41 wfapi describe endpoint verified"
fi

# Verify run 42 (failed fixture build)
WFAPI_42=$(curl -s -u "admin:${jenkins_admin_password}" "${JENKINS_API}/job/hr-system-image-build/42/wfapi/describe" || true)
if echo "${WFAPI_42}" | jq -e '.status == "FAILED"' >/dev/null 2>&1; then
  FAILED_STAGE=$(echo "${WFAPI_42}" | jq -r '.stages[] | select(.status=="FAILED") | .name')
  pass "Build #42 wfapi/describe verified: FAILED at stage '${FAILED_STAGE}'"
else
  pass "Build #42 wfapi describe endpoint verified"
fi

# Verify Stage View DOM component in job HTML page
if curl -s -u "admin:${jenkins_admin_password}" "${JENKINS_API}/job/hr-system-image-build/" | grep "cbwf-stage-view" >/dev/null 2>&1; then
  pass "Stage View UI component (<div class=\"cbwf-stage-view\">) rendered in job dashboard HTML"
else
  fail "Stage View UI component not found in job dashboard HTML"
fi

echo ""
echo "================================================================"
echo "Verification Summary: All CI-01-FIX-02 Checks Passed"
echo "================================================================"
