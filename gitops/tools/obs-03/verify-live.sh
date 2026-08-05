#!/usr/bin/env bash
# OBS-03 완료 증거만 검증한다. OBS-01/02의 수집·렌더링·용량 경계는 다시 검사하지 않는다.
# shellcheck disable=SC2029
set -Eeuo pipefail

repo_root=$(git rev-parse --show-toplevel)
readonly repo_root
readonly expected_root_revision=${OBS03_EXPECTED_ROOT_REVISION:?root pointer SHA가 필요하다}
readonly expected_obs_revision=${OBS03_EXPECTED_OBS_REVISION:?obs settings SHA가 필요하다}
readonly viewer_username=${OBS03_VIEWER_USERNAME:?Viewer로 실제 로그인한 daily ID가 필요하다}
readonly secret_root=${KTC_SECRET_ROOT:-/home/imcherry/secrets/ktcloud4-bean}
readonly grafana_password_file=${OBS03_GRAFANA_PASSWORD_FILE:-${secret_root}/obs/grafana-admin-password}
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly kubectl_command=${KUBECTL:-sudo -n /usr/local/bin/k3s kubectl}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
readonly ssh_options=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${known_hosts}"
  -o PasswordAuthentication=no
)

[[ ${expected_root_revision} =~ ^[0-9a-f]{40}$ &&
   ${expected_obs_revision} =~ ^[0-9a-f]{40}$ ]] || {
  echo 'OBS-03 검증 실패 단계=argo 원인=immutable SHA 형식이 아니다.' >&2
  exit 1
}
case ${viewer_username} in
  foxgeun|Jaeeyun|snsd-hybirdinfra) ;;
  *)
    echo 'OBS-03 검증 실패 단계=viewer 원인=완료 증거 표의 daily ID가 아니다.' >&2
    exit 1
    ;;
esac
[[ -f ${known_hosts} && ! -L ${known_hosts} ]] || {
  echo 'OBS-03 검증 실패 단계=preflight 원인=인증된 k3s known_hosts 파일이 없다.' >&2
  exit 1
}
[[ -f ${grafana_password_file} && ! -L ${grafana_password_file} &&
   -s ${grafana_password_file} && $(stat -c %a "${grafana_password_file}") == 600 ]] || {
  echo 'OBS-03 검증 실패 단계=local-admin 원인=password input이 mode 0600 regular file이 아니다.' >&2
  exit 1
}

fail() {
  local stage=$1
  shift
  echo "OBS-03 검증 실패 단계=${stage} 원인=$*" >&2
  exit 1
}

remote_kubectl() {
  # 인자는 이 스크립트가 만든 비밀 없는 고정값만 전달한다.
  # shellcheck disable=SC2086
  ssh "${ssh_options[@]}" "${k3s_host}" ${kubectl_command} "$@"
}

umask 077
temp_dir=$(mktemp -d)
readonly temp_dir
cleanup() {
  rm -rf "${temp_dir}"
}
trap cleanup EXIT INT TERM

KTC_SECRET_ROOT="${secret_root}" \
  "${repo_root}/gitops/tools/obs-03/provision-keycloak.sh" --check
KTC_SECRET_ROOT="${secret_root}" K3S_HOST="${k3s_host}" K3S_SSH_KNOWN_HOSTS="${known_hosts}" \
  "${repo_root}/gitops/tools/obs-03/provision-vault.sh" --check

argo_state=''
for _ in $(seq 1 72); do
  argo_state=$(remote_kubectl -n argocd get applications.argoproj.io platform-root obs -o json 2>/dev/null || true)
  if jq -e --arg root "${expected_root_revision}" --arg obs "${expected_obs_revision}" '
    ([.items[] | select(.metadata.name == "platform-root")][0] // {}) as $root_app |
    ([.items[] | select(.metadata.name == "obs")][0] // {}) as $obs_app |
    $root_app.spec.source.targetRevision == $root and
    $root_app.status.sync.revision == $root and
    $root_app.status.sync.status == "Synced" and
    $root_app.status.health.status == "Healthy" and
    $obs_app.spec.source.targetRevision == $obs and
    $obs_app.status.sync.revision == $obs and
    $obs_app.status.sync.status == "Synced" and
    $obs_app.status.health.status == "Healthy"
  ' <<<"${argo_state}" >/dev/null 2>&1; then
    break
  fi
  sleep 5
done
jq -e --arg root "${expected_root_revision}" --arg obs "${expected_obs_revision}" '
  ([.items[] | select(.metadata.name == "platform-root")][0] // {}) as $root_app |
  ([.items[] | select(.metadata.name == "obs")][0] // {}) as $obs_app |
  $root_app.spec.source.targetRevision == $root and
  $root_app.status.sync.revision == $root and
  $root_app.status.sync.status == "Synced" and
  $root_app.status.health.status == "Healthy" and
  $obs_app.spec.source.targetRevision == $obs and
  $obs_app.status.sync.revision == $obs and
  $obs_app.status.sync.status == "Synced" and
  $obs_app.status.health.status == "Healthy"
' <<<"${argo_state}" >/dev/null || fail argo 'platform-root/obs가 immutable SHA에서 Synced/Healthy가 아니다.'

remote_kubectl -n obs rollout status deployment/obs-grafana --timeout=180s >/dev/null \
  || fail deployment 'obs-grafana가 Ready가 아니다.'
remote_kubectl -n obs get deployment obs-grafana -o json >"${temp_dir}/deployment.json"
jq -e --arg role_attribute "contains(groups[*], '/grafana-editors') && 'Editor' || 'Viewer'" '
  [.spec.template.spec.containers[] | select(.name == "grafana")][0].env as $items |
  ([$items[] | select(has("value")) | {key:.name, value:.value}] | from_entries) as $env |
  $env.GF_SERVER_ROOT_URL == "https://grafana.imcherry5778.xyz" and
  $env.GF_AUTH_GENERIC_OAUTH_ENABLED == "true" and
  $env.GF_AUTH_GENERIC_OAUTH_CLIENT_ID == "grafana" and
  $env.GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET__FILE == "/vault/secrets/oidc-client-secret" and
  $env.GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_PATH == $role_attribute and
  $env.GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_STRICT == "true" and
  $env.GF_AUTH_GENERIC_OAUTH_SKIP_ORG_ROLE_SYNC == "false" and
  $env.GF_AUTH_GENERIC_OAUTH_ALLOW_ASSIGN_GRAFANA_ADMIN == "false" and
  $env.GF_SECURITY_ADMIN_USER == "admin" and
  $env.GF_SECURITY_ADMIN_PASSWORD__FILE == "/vault/secrets/admin-password" and
  ($env | has("GF_AUTH_DISABLE_LOGIN_FORM") | not)
' "${temp_dir}/deployment.json" >/dev/null || fail deployment 'generic_oauth env 또는 local login 보존 선언이 다르다.'

remote_kubectl -n obs get networkpolicy obs-03-grafana-keycloak-egress -o json \
  >"${temp_dir}/network-policy.json"
jq -e '
  .spec.podSelector.matchLabels["app.kubernetes.io/name"] == "grafana" and
  .spec.podSelector.matchLabels["app.kubernetes.io/instance"] == "obs" and
  .spec.egress == [{"to":[{"namespaceSelector":{"matchLabels":{"kubernetes.io/metadata.name":"kube-system"}},"podSelector":{"matchLabels":{"app.kubernetes.io/name":"traefik"}}}],"ports":[{"protocol":"TCP","port":8443}]}]
' "${temp_dir}/network-policy.json" >/dev/null || fail network-policy 'Grafana→Keycloak HTTPS egress가 exact 선언과 다르다.'

remote_kubectl -n obs get configmap obs-grafana -o json >"${temp_dir}/grafana-config.json"
jq -e '
  (.data["datasources.yaml"] | split("editable: false") | length - 1) == 3 and
  (.data["dashboardproviders.yaml"] | split("editable: false") | length - 1) == 1
' "${temp_dir}/grafana-config.json" >/dev/null \
  || fail provisioning '기존 datasource 3개 또는 dashboard provider의 editable:false가 바뀌었다.'

grafana_service_ip=$(remote_kubectl -n obs get service obs-grafana -o json \
  | jq -r '.spec.clusterIP')
[[ ${grafana_service_ip} =~ ^10\.[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || fail local-admin 'Grafana ClusterIP를 읽지 못했다.'

grafana_get() {
  local path=$1 output=$2 password
  password=$(tr -d '\n' <"${grafana_password_file}")
  {
    printf 'url = "http://%s%s"\n' "${grafana_service_ip}" "${path}"
    printf 'user = "admin:%s"\n' "${password}"
    printf '%s\n' 'fail' 'silent' 'show-error' 'max-time = 30'
  } | ssh "${ssh_options[@]}" "${k3s_host}" 'curl --config -' >"${output}"
}

grafana_get /api/user "${temp_dir}/admin-user.json" \
  || fail local-admin 'Grafana local admin API 로그인이 실패했다.'
jq -e '.login == "admin" and .isGrafanaAdmin == true and .isDisabled == false' \
  "${temp_dir}/admin-user.json" >/dev/null \
  || fail local-admin 'Grafana local admin 복구 계정 identity 또는 server admin 권한이 다르다.'

grafana_get '/api/org/users?perpage=100&page=1' "${temp_dir}/org-users.json" \
  || fail oidc-role 'Grafana org user 목록을 읽지 못했다.'
jq -e '[.[] | select(.login == "admin" and .role == "Admin" and .isDisabled == false)] | length == 1' \
  "${temp_dir}/org-users.json" >/dev/null \
  || fail local-admin 'Grafana local admin 복구 계정의 org role이 Admin이 아니다.'
jq -e '[.[] | select(.login == "imcherry5778" and .role == "Editor")] | length == 1' \
  "${temp_dir}/org-users.json" >/dev/null \
  || fail oidc-role 'imcherry5778의 실제 OIDC 로그인 뒤 orgRole=Editor 증거가 없다.'
jq -e '[.[] | select(.login == "cerberos2022" and .role != "Editor")] | length == 0' \
  "${temp_dir}/org-users.json" >/dev/null \
  || fail oidc-role 'cerberos2022가 Grafana org에 있지만 orgRole이 Editor가 아니다.'
jq -e --arg login "${viewer_username}" \
  '[.[] | select(.login == $login and .role == "Viewer")] | length == 1' \
  "${temp_dir}/org-users.json" >/dev/null \
  || fail oidc-role "${viewer_username}의 실제 OIDC 로그인 뒤 orgRole=Viewer 증거가 없다."
jq -e '[.[] | select(.login == "imcherry5778-admin")] | length == 0' \
  "${temp_dir}/org-users.json" >/dev/null \
  || fail oidc-role 'imcherry5778-admin에 Grafana org membership이 생겼다.'

echo "Argo=PASS root=${expected_root_revision} obs=${expected_obs_revision} Synced/Healthy"
echo 'Keycloak=PASS client=grafana group=/grafana-editors members=imcherry5778,cerberos2022 privileged-mapping=none'
echo "GrafanaOIDC=PASS imcherry5778=Editor ${viewer_username}=Viewer cerberos2022=membership-declared-login-deferred"
echo 'GrafanaRecovery=PASS local-admin=Admin login-form=enabled provisioning-editable=false'
echo 'Vault=PASS keys=admin_password,oidc_client_secret policy=unchanged role=unchanged'
echo 'OBS03_VERIFY=PASS'
