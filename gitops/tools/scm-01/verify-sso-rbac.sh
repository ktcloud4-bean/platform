#!/usr/bin/env bash
# SCM-01 완료 증거 2: 같은 시점 SSO allow/deny와 IdP 장애 중 local admin login.
# shellcheck disable=SC2029
set -Eeuo pipefail

: "${KTC_SECRET_ROOT:=$HOME/secrets/ktcloud4-bean}"
readonly env_file=${SCM01_ENV_FILE:-"$KTC_SECRET_ROOT/gitea/env"}
readonly kc_secret_dir=${KC01_SECRET_DIR:-"$KTC_SECRET_ROOT/keycloak"}
readonly issuer=https://sso.imcherry5778.xyz
readonly issuer_host=sso.imcherry5778.xyz
readonly connect_ip=${SCM01_CONNECT_IP:-10.10.20.10}
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly kubectl_command=${KUBECTL:-sudo /usr/local/bin/k3s kubectl}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-$HOME/.ssh/known_hosts}
readonly local_port=${SCM01_LOCAL_PORT:-33000}
repo_root=$(git rev-parse --show-toplevel)
readonly repo_root
ssh_options=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${known_hosts}"
)

check_private_file() {
  local path=$1
  [[ -f "${path}" && ! -L "${path}" ]] || { echo "private input file invalid: ${path}" >&2; exit 1; }
  [[ "$(stat -c %u "${path}")" -eq "$(id -u)" && "$(stat -c %a "${path}")" == 600 ]] || {
    echo "private input must be caller-owned mode 0600: ${path}" >&2
    exit 1
  }
}
check_private_file "${env_file}"
for required in daily-password daily-totp privileged-password privileged-totp local-admin-password local-admin-totp; do
  check_private_file "${kc_secret_dir}/${required}"
done

local_admin_password=$(awk -F= '$1=="GITEA_LOCAL_ADMIN_PASSWORD"{print substr($0,index($0,"=")+1)}' "${env_file}")
[[ "${local_admin_password}" =~ ^[A-Za-z0-9]{32,}$ ]]

umask 077
temp_dir=$(mktemp -d)
readonly temp_dir
admin_header=${temp_dir}/admin.header
local_password_file=${temp_dir}/local-admin-password
printf '%s\n' "${local_admin_password}" >"${local_password_file}"
realm_disabled=false
port_forward_pid=

cleanup() {
  local status=$?
  set +e
  if [[ -n "${port_forward_pid}" ]]; then
    kill "${port_forward_pid}" 2>/dev/null
    wait "${port_forward_pid}" 2>/dev/null
  fi
  if [[ "${realm_disabled}" == true && -s "${admin_header}" ]]; then
    printf '{"enabled":true}\n' >"${temp_dir}/enable.json"
    curl --silent --show-error --output /dev/null \
      --resolve "${issuer_host}:443:${connect_ip}" --request PUT \
      --header "@${admin_header}" --header 'Content-Type: application/json' \
      --data-binary "@${temp_dir}/enable.json" "${issuer}/admin/realms/platform"
  fi
  rm -rf "${temp_dir}"
  exit "${status}"
}
trap cleanup EXIT INT TERM

echo "SCM-01 SSO/RBAC: /platform-users allow와 비허용 그룹 deny를 같은 실행에서 대조합니다."
node "${repo_root}/gitops/tools/scm-01/gitea-browser.js" \
  --connect-ip "${connect_ip}" --username imcherry \
  --password-file "${kc_secret_dir}/daily-password" \
  --totp-file "${kc_secret_dir}/daily-totp" --expect allow
node "${repo_root}/gitops/tools/scm-01/gitea-browser.js" \
  --connect-ip "${connect_ip}" --username imcherry-admin \
  --password-file "${kc_secret_dir}/privileged-password" \
  --totp-file "${kc_secret_dir}/privileged-totp" --expect deny

ssh "${ssh_options[@]}" "${k3s_host}" \
  "${kubectl_command} -n gitea exec deployment/gitea -c gitea -- \
    /usr/local/bin/gitea admin user list --admin --config /etc/gitea/app.ini" \
  | awk '$2 == "scm-recovery" { found = 1 } END { exit !found }'

wait_seconds=$((31 - $(date +%s) % 30))
sleep "${wait_seconds}"
python3 "${repo_root}/gitops/tools/kc-01/browser-login.py" \
  --issuer "${issuer}" --realm master --client-id kc-recovery \
  --redirect-uri "${issuer}/realms/master/account/" \
  --username imcherry-kc-recovery \
  --password-file "${kc_secret_dir}/local-admin-password" \
  --totp-file "${kc_secret_dir}/local-admin-totp" \
  --header-file "${admin_header}" --connect-ip "${connect_ip}" \
  --expect-realm-role admin >/dev/null

printf '{"enabled":false}\n' >"${temp_dir}/disable.json"
http_status=$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
  --resolve "${issuer_host}:443:${connect_ip}" --request PUT \
  --header "@${admin_header}" --header 'Content-Type: application/json' \
  --data-binary "@${temp_dir}/disable.json" "${issuer}/admin/realms/platform")
[[ "${http_status}" == 204 ]]
realm_disabled=true

service_ip=$(ssh "${ssh_options[@]}" "${k3s_host}" \
  "${kubectl_command} -n gitea get service/gitea-http -o jsonpath='{.spec.clusterIP}'")
[[ "${service_ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || {
  echo "gitea-http service did not resolve to IPv4" >&2
  exit 1
}
ssh "${ssh_options[@]}" -o ExitOnForwardFailure=yes -N \
  -L "${local_port}:${service_ip}:3000" "${k3s_host}" \
  >"${temp_dir}/port-forward.log" 2>&1 &
port_forward_pid=$!
for _ in $(seq 1 30); do
  if curl --silent --show-error --fail \
    --header 'Host: git.imcherry5778.xyz' --header 'X-Forwarded-Proto: https' \
    "http://127.0.0.1:${local_port}/api/healthz" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
curl --silent --show-error --fail \
  --header 'Host: git.imcherry5778.xyz' --header 'X-Forwarded-Proto: https' \
  "http://127.0.0.1:${local_port}/api/healthz" >/dev/null
python3 "${repo_root}/gitops/tools/scm-01/local-login.py" \
  --port "${local_port}" --password-file "${local_password_file}"

printf '{"enabled":true}\n' >"${temp_dir}/enable.json"
http_status=$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
  --resolve "${issuer_host}:443:${connect_ip}" --request PUT \
  --header "@${admin_header}" --header 'Content-Type: application/json' \
  --data-binary "@${temp_dir}/enable.json" "${issuer}/admin/realms/platform")
[[ "${http_status}" == 204 ]]
realm_disabled=false
echo "SCM-01 SSO/RBAC: Keycloak OIDC allow, 비허용 그룹 403, IdP disabled 중 local admin login 통과"
