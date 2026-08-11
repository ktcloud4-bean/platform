#!/usr/bin/env bash
# WAZUH-02-FIX-01 완료 증거 단일 진입점. 기존 WAZUH-01/02의 수집·Pomerium Route·보존
# 경계는 재판정하지 않고 Wazuh native OIDC와 그 최소 회귀만 확인한다.
set -Eeuo pipefail

readonly repo_root=$(git rev-parse --show-toplevel)
readonly secret_root=${KTC_SECRET_ROOT:-/home/imcherry/secrets/ktcloud4-bean}
readonly kc_secret_dir=${KC01_SECRET_DIR:-${secret_root}/keycloak}
readonly connect_ip=${WAZUH02_CONNECT_IP:-10.10.20.10}
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
readonly kubectl_command=${KUBECTL:-sudo -n /usr/local/bin/k3s kubectl}
readonly expected_root_revision=${WAZUH02FIX01_EXPECTED_ROOT_REVISION:?root pointer SHA가 필요하다}
readonly expected_wazuh_revision=${WAZUH02FIX01_EXPECTED_WAZUH_REVISION:?wazuh child SHA가 필요하다}
readonly ssh_options=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${known_hosts}"
)

[[ ${expected_root_revision} =~ ^[0-9a-f]{40}$ && ${expected_wazuh_revision} =~ ^[0-9a-f]{40}$ ]] || {
  echo 'WAZUH-02-FIX-01 검증 실패 단계=preflight 원인=immutable SHA 형식이 아니다.' >&2
  exit 1
}
[[ -f ${known_hosts} && ! -L ${known_hosts} ]] || {
  echo 'WAZUH-02-FIX-01 검증 실패 단계=preflight 원인=인증된 k3s known_hosts 파일이 없다.' >&2
  exit 1
}

fail() {
  echo "WAZUH-02-FIX-01 검증 실패 단계=$1 원인=$2" >&2
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

remote_kubectl -n wazuh rollout status statefulset/wazuh-indexer --timeout=180s >/dev/null \
  || fail workload 'wazuh-indexer가 Ready가 아니다.'
remote_kubectl -n wazuh rollout status deployment/wazuh-dashboard --timeout=180s >/dev/null \
  || fail workload 'wazuh-dashboard가 Ready가 아니다.'
remote_kubectl -n wazuh wait --for=condition=complete job/wazuh-oidc-security-sync-v2 --timeout=180s >/dev/null \
  || fail security-sync 'OIDC security sync Job이 Complete가 아니다.'
echo 'Workload=PASS indexer/dashboard/oidc-security-sync'

keycloak_result=$("${repo_root}/gitops/tools/wazuh-02-fix-01/provision-keycloak.sh" --check)
grep -qx 'WAZUH-02-FIX-01 Keycloak=PASS client=wazuh role=wazuh-admin group=/platform-privileged user-change=0' \
  <<<"${keycloak_result}" || fail keycloak 'confidential client, role, group mapping이 선언과 다르다.'
vault_result=$("${repo_root}/gitops/tools/wazuh-02-fix-01/provision-vault.sh" --check)
grep -qx 'VaultWazuhOidc=PASS path=kv/wazuh/dashboard key=oidc_client_secret' <<<"${vault_result}" \
  || fail vault 'Dashboard OIDC client secret Vault key가 선언과 다르다.'
echo 'IdentityInput=PASS keycloak-client-role vault-key'

indexer_pod=$(remote_kubectl -n wazuh get pod -l app.kubernetes.io/component=indexer \
  -o jsonpath='{.items[0].metadata.name}')
[[ -n ${indexer_pod} ]] || fail security-config 'indexer Pod를 찾지 못했다.'
indexer_api() {
  remote_kubectl -n wazuh exec "${indexer_pod}" -c wazuh-indexer -- \
    curl --silent --show-error --fail \
      --cacert /usr/share/wazuh-indexer/config/certs/root-ca.pem \
      --cert /usr/share/wazuh-indexer/config/certs/admin.pem \
      --key /usr/share/wazuh-indexer/config/certs/admin-key.pem \
      "https://indexer.wazuh.svc.cluster.local:9200$1"
}
security_config=$(indexer_api /_plugins/_security/api/securityconfig) || fail security-config 'Indexer Security API 조회가 실패했다.'
jq -e '
  (.config.dynamic.authc.openid_auth_domain // {}) as $oidc |
  .config.dynamic.authc.basic_internal_auth_domain.http_authenticator.challenge == true and
  $oidc.http_enabled == true and
  ($oidc.transport_enabled // false) == false and
  $oidc.order == 1 and
  $oidc.http_authenticator == {
    type:"openid",
    challenge:false,
    config:{
      subject_key:"preferred_username",
      roles_key:"wazuh_roles",
      openid_connect_url:"https://sso.imcherry5778.xyz/realms/platform/.well-known/openid-configuration",
      required_audience:"wazuh"
    }
  } and
  $oidc.authentication_backend.type == "noop" and
  ($oidc.authentication_backend.config // {}) == {}
' <<<"${security_config}" >/dev/null || fail security-config 'native OIDC auth domain이 선언과 다르다.'
role_mapping=$(indexer_api /_plugins/_security/api/rolesmapping/all_access) || fail rbac 'Indexer all_access mapping 조회가 실패했다.'
jq -e '(.all_access.backend_roles | sort) == ["admin", "wazuh-admin"]' <<<"${role_mapping}" >/dev/null \
  || fail rbac 'all_access backend role mapping이 선언과 다르다.'
echo 'IndexerSecurity=PASS native-oidc all_access=wazuh-admin'

python3 "${repo_root}/gitops/tools/wazuh-02-fix-01/verify-oidc-browser.py" \
  --repo-root "${repo_root}" --connect-ip "${connect_ip}" \
  --username "${WAZUH02FIX01_PRIVILEGED_USERNAME:-imcherry5778-admin}" \
  --password-file "${KC01_PRIVILEGED_PASSWORD_FILE:-${kc_secret_dir}/privileged-password}" \
  --totp-file "${KC01_PRIVILEGED_TOTP_FILE:-${kc_secret_dir}/privileged-totp}"

echo 'WAZUH02FIX01_VERIFY=PASS'
