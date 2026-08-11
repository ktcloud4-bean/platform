#!/usr/bin/env bash
# AWS-HR-01-BOOTSTRAP-01: 선택한 일상 Keycloak ID 한 명에게만 HR Route admission을 부여한다.
# HR DB row는 같은 이메일을 Secrets Manager에서 읽는 PreSync migration Job이 소유한다.
set -Eeuo pipefail

mode=${1:-}
[[ ${mode} == --check || ${mode} == --apply ]] || {
  echo '사용법: gitops/tools/aws-hr-01/bootstrap-hr-admin.sh --check|--apply' >&2
  exit 2
}

readonly secret_root=${KTC_SECRET_ROOT:-/home/imcherry/secrets/ktcloud4-bean}
readonly keycloak_secret_dir=${KC01_SECRET_DIR:-${secret_root}/keycloak}
readonly issuer=https://sso.imcherry5778.xyz
readonly issuer_host=sso.imcherry5778.xyz
readonly connect_ip=${KC01_CONNECT_IP:-10.10.20.10}
readonly realm=platform
readonly username=imcherry5778
readonly group_name=hr-admins
readonly bootstrap_secret=hr-system-prod/bootstrap/hr-admin
readonly region=ap-northeast-2

for required in local-admin-password local-admin-totp; do
  secret_path=${keycloak_secret_dir}/${required}
  [[ -f ${secret_path} && ! -L ${secret_path} && $(stat -c %a "${secret_path}") == 600 ]] || {
    echo "Keycloak 복구 입력이 mode 0600 regular file이 아니다: ${required}" >&2
    exit 1
  }
done

python3 - "${connect_ip}" <<'PY'
import ipaddress
import sys

assert ipaddress.ip_address(sys.argv[1]).version == 4
PY

umask 077
readonly temp_dir=$(mktemp -d)
cleanup() {
  find "${temp_dir}" -type f -delete
  rmdir "${temp_dir}"
}
trap cleanup EXIT INT TERM

readonly admin_header=${temp_dir}/keycloak-admin.header
python3 gitops/tools/kc-01/browser-login.py \
  --issuer "${issuer}" \
  --realm master \
  --client-id kc-recovery \
  --redirect-uri "${issuer}/realms/master/account/" \
  --username imcherry-kc-recovery \
  --password-file "${keycloak_secret_dir}/local-admin-password" \
  --totp-file "${keycloak_secret_dir}/local-admin-totp" \
  --header-file "${admin_header}" \
  --connect-ip "${connect_ip}" \
  --capture-callback \
  --expect-realm-role admin >/dev/null

curl_admin() {
  curl --silent --show-error --fail \
    --resolve "${issuer_host}:443:${connect_ip}" \
    --header "@${admin_header}" \
    "$@"
}

bootstrap_email=$(aws secretsmanager get-secret-value \
  --secret-id "${bootstrap_secret}" \
  --region "${region}" \
  --query SecretString \
  --output text | jq -er '.email | strings | ascii_downcase')

users=$(curl_admin "${issuer}/admin/realms/${realm}/users?username=${username}&exact=true")
[[ $(jq 'length' <<<"${users}") == 1 ]] || {
  echo '초기 HR 관리자 Keycloak user가 정확히 한 명이 아니다.' >&2
  exit 1
}
jq -e --arg username "${username}" --arg email "${bootstrap_email}" '
  .[0] | .username == $username and .enabled == true and
  ((.email // "") | ascii_downcase) == $email
' <<<"${users}" >/dev/null || {
  echo '선택한 Keycloak user와 Terraform 관리 bootstrap identity가 일치하지 않는다.' >&2
  exit 1
}
readonly user_id=$(jq -r '.[0].id' <<<"${users}")

load_group() {
  curl_admin "${issuer}/admin/realms/${realm}/groups?search=${group_name}&exact=true&briefRepresentation=false" \
    | jq '[.[] | select(.name == "hr-admins" and .path == "/hr-admins")]'
}

groups=$(load_group)
case $(jq 'length' <<<"${groups}") in
  0)
    if [[ ${mode} == --apply ]]; then
      curl_admin --request POST --header 'Content-Type: application/json' \
        --data '{"name":"hr-admins"}' \
        "${issuer}/admin/realms/${realm}/groups" >/dev/null
      groups=$(load_group)
    else
      echo 'AWS-HR bootstrap check: /hr-admins group 생성 필요'
    fi
    ;;
  1) ;;
  *)
    echo '/hr-admins group이 중복되어 변경하지 않는다.' >&2
    exit 1
    ;;
esac

[[ $(jq 'length' <<<"${groups}") == 1 ]] || {
  echo '/hr-admins group 생성 후 정확히 한 건으로 수렴하지 않았다.' >&2
  exit 1
}
readonly group_id=$(jq -r '.[0].id' <<<"${groups}")
user_groups=$(curl_admin "${issuer}/admin/realms/${realm}/users/${user_id}/groups?briefRepresentation=true")
if jq -e '[.[] | select(.path == "/hr-admins")] | length == 0' <<<"${user_groups}" >/dev/null; then
  if [[ ${mode} == --apply ]]; then
    curl_admin --request PUT --header 'Content-Type: application/json' --data '{}' \
      "${issuer}/admin/realms/${realm}/users/${user_id}/groups/${group_id}" >/dev/null
    user_groups=$(curl_admin "${issuer}/admin/realms/${realm}/users/${user_id}/groups?briefRepresentation=true")
  else
    echo 'AWS-HR bootstrap check: selected user /hr-admins membership 추가 필요'
  fi
fi

jq -e '[.[] | select(.path == "/hr-admins")] | length == 1' <<<"${user_groups}" >/dev/null || {
  echo 'selected user의 /hr-admins membership이 정확히 한 건으로 수렴하지 않았다.' >&2
  exit 1
}

unset bootstrap_email users user_groups
echo "AWS-HR bootstrap Keycloak=PASS user=${username} group=/hr-admins"
