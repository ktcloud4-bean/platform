#!/usr/bin/env bash
# AWS-HR-03: 선택된 팀 일상 ID의 HR 직원 포털 admission만 최소권한으로 수렴시킨다.
set -Eeuo pipefail

mode=${1:-}
[[ ${mode} == --check || ${mode} == --apply ]] || {
  echo '사용법: gitops/tools/aws-hr-03/manage-employee-portal-users.sh --check|--apply' >&2
  exit 2
}

readonly secret_root=${KTC_SECRET_ROOT:-/home/imcherry/secrets/ktcloud4-bean}
readonly keycloak_secret_dir=${KC01_SECRET_DIR:-${secret_root}/keycloak}
readonly issuer=https://sso.imcherry5778.xyz
readonly issuer_host=sso.imcherry5778.xyz
readonly connect_ip=${KC01_CONNECT_IP:-10.10.20.10}
readonly realm=platform
readonly employee_group_name=hr-users
readonly admin_group_name=hr-admins
readonly target_usernames=(foxgeun cerberos2022 jaeeyun snsd-hybirdinfra)

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

exact_group() {
  local group_name=$1
  local groups
  groups=$(curl_admin "${issuer}/admin/realms/${realm}/groups?search=${group_name}&exact=true&briefRepresentation=false" \
    | jq --arg name "${group_name}" '[.[] | select(.name == $name and .path == ("/" + $name))]')
  [[ $(jq 'length' <<<"${groups}") == 1 ]] || {
    echo "/${group_name} group이 정확히 한 건이 아니어서 변경하지 않는다." >&2
    exit 1
  }
  printf '%s' "${groups}"
}

readonly employee_group=$(exact_group "${employee_group_name}")
readonly employee_group_id=$(jq -r '.[0].id' <<<"${employee_group}")
readonly employee_group_representation=$(jq -c '.[0]' <<<"${employee_group}")
readonly admin_group=$(exact_group "${admin_group_name}")
readonly admin_group_id=$(jq -r '.[0].id' <<<"${admin_group}")

declare -A user_ids
declare -A employee_membership_counts

for username in "${target_usernames[@]}"; do
  users=$(curl_admin "${issuer}/admin/realms/${realm}/users?username=${username}&exact=true&briefRepresentation=false" \
    | jq --arg username "${username}" '[.[] | select(.username == $username and .enabled == true)]')
  [[ $(jq 'length' <<<"${users}") == 1 ]] || {
    echo "${username}: enabled Keycloak daily ID가 정확히 한 건이 아니어서 변경하지 않는다." >&2
    exit 1
  }

  user_id=$(jq -r '.[0].id' <<<"${users}")
  user_groups=$(curl_admin "${issuer}/admin/realms/${realm}/users/${user_id}/groups?first=0&max=100&briefRepresentation=true")
  employee_membership_count=$(jq --arg id "${employee_group_id}" '[.[] | select(.id == $id)] | length' <<<"${user_groups}")
  admin_membership_count=$(jq --arg id "${admin_group_id}" '[.[] | select(.id == $id)] | length' <<<"${user_groups}")

  [[ ${employee_membership_count} == 0 || ${employee_membership_count} == 1 ]] || {
    echo "${username}: /${employee_group_name} membership이 중복되어 변경하지 않는다." >&2
    exit 1
  }
  [[ ${admin_membership_count} == 0 ]] || {
    echo "${username}: /${admin_group_name} membership이 있어 직원 권한 작업을 중단한다." >&2
    exit 1
  }

  user_ids[${username}]=${user_id}
  employee_membership_counts[${username}]=${employee_membership_count}
done

added=0
unchanged=0
for username in "${target_usernames[@]}"; do
  if [[ ${employee_membership_counts[${username}]} == 1 ]]; then
    ((unchanged += 1))
    continue
  fi

  if [[ ${mode} == --check ]]; then
    continue
  fi

  curl_admin --request PUT --header 'Content-Type: application/json' \
    --data "${employee_group_representation}" \
    "${issuer}/admin/realms/${realm}/users/${user_ids[${username}]}/groups/${employee_group_id}" >/dev/null

  user_groups=$(curl_admin "${issuer}/admin/realms/${realm}/users/${user_ids[${username}]}/groups?first=0&max=100&briefRepresentation=true")
  employee_membership_count=$(jq --arg id "${employee_group_id}" '[.[] | select(.id == $id)] | length' <<<"${user_groups}")
  admin_membership_count=$(jq --arg id "${admin_group_id}" '[.[] | select(.id == $id)] | length' <<<"${user_groups}")
  [[ ${employee_membership_count} == 1 && ${admin_membership_count} == 0 ]] || {
    echo "${username}: 적용 뒤 HR group membership 검증에 실패했다." >&2
    exit 1
  }
  ((added += 1))
done

if [[ ${mode} == --check ]]; then
  needed=0
  for username in "${target_usernames[@]}"; do
    if [[ ${employee_membership_counts[${username}]} == 0 ]]; then
      ((needed += 1))
    fi
  done
  echo "AWS-HR-03 Keycloak=PASS users=${#target_usernames[@]}/${#target_usernames[@]} employee_group=/${employee_group_name} add_needed=${needed} admin_membership=0"
else
  echo "AWS-HR-03 Keycloak=PASS users=${#target_usernames[@]}/${#target_usernames[@]} employee_group=/${employee_group_name} added=${added} unchanged=${unchanged} admin_membership=0"
fi
