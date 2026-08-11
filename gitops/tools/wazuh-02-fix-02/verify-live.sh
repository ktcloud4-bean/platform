#!/usr/bin/env bash
# WAZUH-02-FIX-02 완료 증거 단일 진입점. WAZUH-02-FIX-01의 Keycloak client,
# Indexer RBAC와 Pomerium Route는 그대로 두고 Dashboard 로그인 선택 UI와 Server API URL만 판정한다.
set -Eeuo pipefail

repo_root=$(git rev-parse --show-toplevel)
readonly repo_root
readonly secret_root=${KTC_SECRET_ROOT:-/home/imcherry/secrets/ktcloud4-bean}
readonly kc_secret_dir=${KC01_SECRET_DIR:-${secret_root}/keycloak}
readonly connect_ip=${WAZUH02_CONNECT_IP:-10.10.20.10}
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
readonly kubectl_command=${KUBECTL:-sudo -n /usr/local/bin/k3s kubectl}
readonly expected_root_revision=${WAZUH02FIX02_EXPECTED_ROOT_REVISION:?root pointer SHA가 필요하다}
readonly expected_wazuh_revision=${WAZUH02FIX02_EXPECTED_WAZUH_REVISION:?wazuh child SHA가 필요하다}
readonly ssh_options=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${known_hosts}"
)

[[ ${expected_root_revision} =~ ^[0-9a-f]{40}$ && ${expected_wazuh_revision} =~ ^[0-9a-f]{40}$ ]] || {
  echo 'WAZUH-02-FIX-02 검증 실패 단계=preflight 원인=immutable SHA 형식이 아니다.' >&2
  exit 1
}
[[ -f ${known_hosts} && ! -L ${known_hosts} ]] || {
  echo 'WAZUH-02-FIX-02 검증 실패 단계=preflight 원인=인증된 k3s known_hosts 파일이 없다.' >&2
  exit 1
}

fail() {
  echo "WAZUH-02-FIX-02 검증 실패 단계=$1 원인=$2" >&2
  exit 1
}

remote_kubectl() {
  # shellcheck disable=SC2029,SC2086
  ssh "${ssh_options[@]}" "${k3s_host}" ${kubectl_command} "$@"
}

argo_state=''
for _ in $(seq 1 72); do
  argo_state=$(remote_kubectl -n argocd get applications.argoproj.io platform-root wazuh -o json 2>/dev/null || true)
  if jq -e --arg root "${expected_root_revision}" --arg wazuh "${expected_wazuh_revision}" '
    ([.items[] | select(.metadata.name == "platform-root")][0] // {}) as $root_app |
    ([.items[] | select(.metadata.name == "wazuh")][0] // {}) as $wazuh_app |
    $root_app.spec.source.targetRevision == $root and
    $root_app.status.sync.revision == $root and $root_app.status.sync.status == "Synced" and
    $root_app.status.health.status == "Healthy" and
    $wazuh_app.spec.source.targetRevision == $wazuh and
    $wazuh_app.status.sync.revision == $wazuh and $wazuh_app.status.sync.status == "Synced" and
    $wazuh_app.status.health.status == "Healthy"
  ' <<<"${argo_state}" >/dev/null 2>&1; then
    break
  fi
  sleep 5
done
jq -e --arg root "${expected_root_revision}" --arg wazuh "${expected_wazuh_revision}" '
  ([.items[] | select(.metadata.name == "platform-root")][0] // {}) as $root_app |
  ([.items[] | select(.metadata.name == "wazuh")][0] // {}) as $wazuh_app |
  $root_app.spec.source.targetRevision == $root and $root_app.status.sync.revision == $root and
  $root_app.status.sync.status == "Synced" and $root_app.status.health.status == "Healthy" and
  $wazuh_app.spec.source.targetRevision == $wazuh and $wazuh_app.status.sync.revision == $wazuh and
  $wazuh_app.status.sync.status == "Synced" and $wazuh_app.status.health.status == "Healthy"
' <<<"${argo_state}" >/dev/null || fail argo 'platform-root/wazuh가 immutable SHA에서 Synced/Healthy가 아니다.'
echo "Argo=PASS root=${expected_root_revision} wazuh=${expected_wazuh_revision}"

remote_kubectl -n wazuh rollout status deployment/wazuh-dashboard --timeout=180s >/dev/null \
  || fail workload 'wazuh-dashboard가 Ready가 아니다.'
dashboard_config=$(remote_kubectl -n wazuh get configmap wazuh-dashboard-conf -o json) \
  || fail config 'wazuh-dashboard-conf 조회가 실패했다.'
jq -e '
  .data["opensearch_dashboards.yml"] as $config |
  ($config | test("(?m)^opensearch_security\\.auth\\.multiple_auth_enabled: true$")) and
  ($config | test("(?m)^opensearch_security\\.auth\\.type: \\[\\\"basicauth\\\", \\\"openid\\\"\\]$")) and
  ($config | test("(?m)^opensearch_security\\.ui\\.openid\\.login\\.buttonname: \\\"Keycloak SSO로 로그인\\\"$")) and
  ($config | test("(?m)^opensearch_security\\.openid\\.client_id: \\\"wazuh\\\"$"))
' <<<"${dashboard_config}" >/dev/null || fail config 'Dashboard multi-auth OIDC 선택 UI 선언이 다르다.'
dashboard_url=$(remote_kubectl -n wazuh get deployment wazuh-dashboard -o json | jq -r '
  .spec.template.spec.containers[] | select(.name == "wazuh-dashboard") |
  .env[] | select(.name == "WAZUH_API_URL") | .value
')
[[ ${dashboard_url} == https://wazuh.wazuh.svc.cluster.local ]] \
  || fail config 'WAZUH_API_URL이 port 없는 Manager Service scheme/host가 아니다.'
echo 'DashboardConfig=PASS selector=basicauth+openid button=Keycloak-SSO manager-url=single-port'

python3 "${repo_root}/gitops/tools/wazuh-02-fix-02/verify-oauth-ui-browser.py" \
  --repo-root "${repo_root}" --connect-ip "${connect_ip}" \
  --username "${WAZUH02FIX02_PRIVILEGED_USERNAME:-imcherry5778-admin}" \
  --password-file "${KC01_PRIVILEGED_PASSWORD_FILE:-${kc_secret_dir}/privileged-password}" \
  --totp-file "${KC01_PRIVILEGED_TOTP_FILE:-${kc_secret_dir}/privileged-totp}"

echo 'WAZUH02FIX02_VERIFY=PASS'
