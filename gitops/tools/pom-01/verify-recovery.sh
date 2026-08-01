#!/usr/bin/env bash
# shellcheck disable=SC2029
# platform realm을 잠시 비활성화한 동안 break-glass k3s 경로로 Pomerium을 조회·재생성한다.
# 사용자 승인과 즉시 원복 시간을 확보한 뒤에만 실행한다.
set -Eeuo pipefail

: "${KC01_SECRET_DIR:?저장소 밖 KC-01 비밀 디렉터리가 필요하다}"
readonly issuer=https://sso.imcherry5778.xyz
readonly issuer_host=sso.imcherry5778.xyz
readonly connect_ip=${KC01_CONNECT_IP:-10.10.20.10}
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly kubectl_command=${KUBECTL:-sudo /usr/local/bin/k3s kubectl}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
readonly expected_root_revision=${POM01_EXPECTED_ROOT_REVISION:-main}
readonly expected_app_revision=${POM01_EXPECTED_APP_REVISION:-main}
repo_root=$(git rev-parse --show-toplevel)
readonly repo_root
ssh_options=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${known_hosts}"
)
temp_dir=$(mktemp -d)
readonly temp_dir
umask 077
realm_disabled=false

cleanup() {
  local cleanup_status=$?
  set +e
  if [[ "${realm_disabled}" == true && -s "${temp_dir}/local.header" ]]; then
    printf '{"enabled":true}\n' >"${temp_dir}/enable.json"
    curl --silent --show-error --output /dev/null \
      --resolve "${issuer_host}:443:${connect_ip}" \
      --request PUT \
      --header "@${temp_dir}/local.header" \
      --header 'Content-Type: application/json' \
      --data-binary "@${temp_dir}/enable.json" \
      "${issuer}/admin/realms/platform"
  fi
  rm -rf "${temp_dir}"
  exit "${cleanup_status}"
}
trap cleanup EXIT INT TERM

for required in \
  verify-client-secret daily-password daily-totp \
  local-admin-password local-admin-totp; do
  [[ -s "${KC01_SECRET_DIR}/${required}" ]] || {
    echo "필수 KC-01 외부 파일이 없다: ${required}" >&2
    exit 1
  }
done

make_daily_form() {
  local output=$1
  python3 - "${output}" \
    "${KC01_SECRET_DIR}/verify-client-secret" \
    "${KC01_SECRET_DIR}/daily-password" \
    "${KC01_SECRET_DIR}/daily-totp" <<'PY'
import base64, hashlib, hmac, struct, sys, time, urllib.parse
output, client_secret_file, password_file, totp_file = sys.argv[1:]
with open(client_secret_file, encoding="utf-8") as stream:
    client_secret = stream.read().strip()
with open(password_file, encoding="utf-8") as stream:
    password = stream.read().strip()
with open(totp_file, encoding="utf-8") as stream:
    seed = base64.b32decode(stream.read().strip(), casefold=True)
remaining = 30 - (int(time.time()) % 30)
if remaining < 4:
    time.sleep(remaining + 1)
counter = int(time.time()) // 30
digest = hmac.new(seed, struct.pack(">Q", counter), hashlib.sha256).digest()
offset = digest[-1] & 0x0F
value = struct.unpack(">I", digest[offset:offset + 4])[0] & 0x7FFFFFFF
form = {
    "grant_type": "password", "client_id": "kc-verify",
    "client_secret": client_secret, "username": "imcherry",
    "password": password, "totp": f"{value % 1_000_000:06d}",
}
with open(output, "w", encoding="utf-8") as stream:
    stream.write(urllib.parse.urlencode(form))
PY
}

echo "POM-01 복구 시험: Vault unsealed, Argo main과 단일 Pomerium Pod를 확인합니다."
vault_status=$(ssh "${ssh_options[@]}" "${k3s_host}" \
  "${kubectl_command} -n vault exec vault-0 -- vault status -format=json")
jq -e '.initialized == true and .sealed == false' <<<"${vault_status}" >/dev/null
argo_state=$(ssh "${ssh_options[@]}" "${k3s_host}" \
  "${kubectl_command} -n argocd get application platform-root pomerium \
    -o jsonpath='{range .items[*]}{.metadata.name}{\"|\"}{.status.sync.status}{\"|\"}{.status.health.status}{\"|\"}{.spec.source.targetRevision}{\"\\n\"}{end}'")
grep -Fxq "platform-root|Synced|Healthy|${expected_root_revision}" <<<"${argo_state}"
grep -Fxq "pomerium|Synced|Healthy|${expected_app_revision}" <<<"${argo_state}"

pod_line=$(ssh "${ssh_options[@]}" "${k3s_host}" \
  "${kubectl_command} -n pomerium get pod -l app.kubernetes.io/name=pomerium \
    -o jsonpath='{range .items[*]}{.metadata.name}{\"|\"}{.metadata.uid}{\"\\n\"}{end}'")
[[ "$(wc -l <<<"${pod_line}")" -eq 1 ]]
old_pod_name=${pod_line%%|*}
old_pod_uid=${pod_line#*|}
traefik_uid=$(ssh "${ssh_options[@]}" "${k3s_host}" \
  "${kubectl_command} -n kube-system get pod -l app.kubernetes.io/name=traefik \
    -o jsonpath='{.items[0].metadata.uid}'")
ssh "${ssh_options[@]}" "${k3s_host}" \
  "${kubectl_command} -n pomerium exec '${old_pod_name}' -c pomerium -- \
    /bin/pomerium health --health-addr 127.0.0.1:28080" >/dev/null

wait_seconds=$((31 - $(date +%s) % 30))
sleep "${wait_seconds}"
python3 "${repo_root}/gitops/tools/kc-01/browser-login.py" \
  --issuer "${issuer}" \
  --realm master \
  --client-id kc-recovery \
  --redirect-uri "${issuer}/realms/master/account/" \
  --username imcherry-kc-recovery \
  --password-file "${KC01_SECRET_DIR}/local-admin-password" \
  --totp-file "${KC01_SECRET_DIR}/local-admin-totp" \
  --header-file "${temp_dir}/local.header" \
  --connect-ip "${connect_ip}" \
  --expect-realm-role admin >/dev/null

http_status=$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
  --resolve "${issuer_host}:443:${connect_ip}" \
  --header "@${temp_dir}/local.header" "${issuer}/admin/realms/platform")
[[ "${http_status}" == 200 ]]

echo "POM-01 복구 시험: platform realm을 일시 비활성화합니다."
printf '{"enabled":false}\n' >"${temp_dir}/disable.json"
http_status=$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
  --resolve "${issuer_host}:443:${connect_ip}" \
  --request PUT \
  --header "@${temp_dir}/local.header" \
  --header 'Content-Type: application/json' \
  --data-binary "@${temp_dir}/disable.json" \
  "${issuer}/admin/realms/platform")
[[ "${http_status}" == 204 ]]
realm_disabled=true

make_daily_form "${temp_dir}/daily-disabled.form"
http_status=$(curl --silent --show-error --output "${temp_dir}/daily-disabled.json" \
  --resolve "${issuer_host}:443:${connect_ip}" \
  --write-out '%{http_code}' \
  --header 'Content-Type: application/x-www-form-urlencoded' \
  --data-binary "@${temp_dir}/daily-disabled.form" \
  "${issuer}/realms/platform/protocol/openid-connect/token")
[[ "${http_status}" == 403 ]]
jq -e '.error == "access_denied" and .error_description == "Realm not enabled"' \
  "${temp_dir}/daily-disabled.json" >/dev/null

echo "POM-01 복구 시험: IdP가 막힌 동안 break-glass kubectl로 health를 조회하고 Pod를 재생성합니다."
ssh "${ssh_options[@]}" "${k3s_host}" \
  "${kubectl_command} -n pomerium exec '${old_pod_name}' -c pomerium -- \
    /bin/pomerium health --health-addr 127.0.0.1:28080" >/dev/null
ssh "${ssh_options[@]}" "${k3s_host}" \
  "${kubectl_command} -n pomerium delete pod '${old_pod_name}' --wait=false" >/dev/null
if ! ssh "${ssh_options[@]}" "${k3s_host}" \
  "${kubectl_command} -n pomerium rollout status deployment/pomerium --timeout=90s" >/dev/null; then
  echo "realm 비활성 상태의 Pomerium Pod 복구가 90초 안에 끝나지 않아 즉시 realm을 원복합니다." >&2
  exit 1
fi
new_pod_line=$(ssh "${ssh_options[@]}" "${k3s_host}" \
  "${kubectl_command} -n pomerium get pod -l app.kubernetes.io/name=pomerium \
    -o jsonpath='{range .items[*]}{.metadata.name}{\"|\"}{.metadata.uid}{\"\\n\"}{end}'")
[[ "$(wc -l <<<"${new_pod_line}")" -eq 1 ]]
new_pod_name=${new_pod_line%%|*}
new_pod_uid=${new_pod_line#*|}
[[ "${new_pod_uid}" != "${old_pod_uid}" ]]
ssh "${ssh_options[@]}" "${k3s_host}" \
  "${kubectl_command} -n pomerium exec '${new_pod_name}' -c pomerium -- \
    /bin/pomerium health --health-addr 127.0.0.1:28080" >/dev/null
traefik_uid_after=$(ssh "${ssh_options[@]}" "${k3s_host}" \
  "${kubectl_command} -n kube-system get pod -l app.kubernetes.io/name=traefik \
    -o jsonpath='{.items[0].metadata.uid}'")
[[ "${traefik_uid_after}" == "${traefik_uid}" ]]

echo "POM-01 복구 시험: master 로컬 관리자 경로로 platform realm을 즉시 원복합니다."
printf '{"enabled":true}\n' >"${temp_dir}/enable.json"
http_status=$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
  --resolve "${issuer_host}:443:${connect_ip}" \
  --request PUT \
  --header "@${temp_dir}/local.header" \
  --header 'Content-Type: application/json' \
  --data-binary "@${temp_dir}/enable.json" \
  "${issuer}/admin/realms/platform")
[[ "${http_status}" == 204 ]]
realm_disabled=false

make_daily_form "${temp_dir}/daily-restored.form"
http_status=$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
  --resolve "${issuer_host}:443:${connect_ip}" \
  --header 'Content-Type: application/x-www-form-urlencoded' \
  --data-binary "@${temp_dir}/daily-restored.form" \
  "${issuer}/realms/platform/protocol/openid-connect/token")
[[ "${http_status}" == 200 ]]
echo "POM-01: Keycloak realm 장애 중 break-glass 조회·Pod 복구와 즉시 원복 검증 통과"
