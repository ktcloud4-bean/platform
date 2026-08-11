#!/usr/bin/env bash
# AWS-HR-03-FIX-01: Git 선언의 HR 포털 group membership만 최소권한으로 수렴시킨다.
set -Eeuo pipefail

mode=${1:-}
[[ ${mode} == --check || ${mode} == --apply ]] || {
  echo '사용법: gitops/tools/aws-hr-03/manage-employee-portal-users.sh --check|--apply' >&2
  exit 2
}

readonly repo_root=$(git rev-parse --show-toplevel)
readonly membership_file=${repo_root}/gitops/tools/aws-hr-03/portal-group-members.json
readonly secret_root=${KTC_SECRET_ROOT:-/home/imcherry/secrets/ktcloud4-bean}
readonly keycloak_secret_dir=${KC01_SECRET_DIR:-${secret_root}/keycloak}
readonly issuer=https://sso.imcherry5778.xyz
readonly issuer_host=sso.imcherry5778.xyz
readonly connect_ip=${KC01_CONNECT_IP:-10.10.20.10}
readonly realm=platform
readonly employee_group_name=hr-users
readonly admin_group_name=hr-admins

[[ -f ${membership_file} && ! -L ${membership_file} ]] || {
  echo 'HR 포털 membership 선언 파일이 regular file이 아니다.' >&2
  exit 1
}
jq -e '
  type == "object" and
  (keys | sort == ["hr-admins", "hr-users"]) and
  ([.[] | type == "array"] | all) and
  ([.[] | .[] | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9-]*$")] | all) and
  ([.[] | length == (unique | length)] | all)
' "${membership_file}" >/dev/null || {
  echo 'HR 포털 membership 선언 형식이 유효하지 않다.' >&2
  exit 1
}

mapfile -t employee_usernames < <(jq -r '."hr-users"[]' "${membership_file}")
mapfile -t admin_usernames < <(jq -r '."hr-admins"[]' "${membership_file}")
mapfile -t all_usernames < <(printf '%s\n' "${employee_usernames[@]}" "${admin_usernames[@]}" | sort -u)
[[ ${#employee_usernames[@]} -gt 0 && ${#admin_usernames[@]} -gt 0 && ${#all_usernames[@]} -gt 0 ]] || {
  echo 'HR 포털 membership 선언이 비어 있다.' >&2
  exit 1
}

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

contains_username() {
  local username=$1
  shift
  local candidate
  for candidate in "$@"; do
    [[ ${candidate} == "${username}" ]] && return 0
  done
  return 1
}

readonly employee_group=$(exact_group "${employee_group_name}")
readonly employee_group_id=$(jq -r '.[0].id' <<<"${employee_group}")
readonly employee_group_representation=$(jq -c '.[0]' <<<"${employee_group}")
readonly admin_group=$(exact_group "${admin_group_name}")
readonly admin_group_id=$(jq -r '.[0].id' <<<"${admin_group}")
readonly admin_group_representation=$(jq -c '.[0]' <<<"${admin_group}")

declare -A user_ids
declare -A employee_membership_counts
declare -A admin_membership_counts

for username in "${all_usernames[@]}"; do
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
  [[ ${admin_membership_count} == 0 || ${admin_membership_count} == 1 ]] || {
    echo "${username}: /${admin_group_name} membership이 중복되어 변경하지 않는다." >&2
    exit 1
  }
  if ! contains_username "${username}" "${admin_usernames[@]}" && [[ ${admin_membership_count} == 1 ]]; then
    echo "${username}: 선언에 없는 /${admin_group_name} membership이 있어 자동 삭제하지 않는다." >&2
    exit 1
  fi

  user_ids[${username}]=${user_id}
  employee_membership_counts[${username}]=${employee_membership_count}
  admin_membership_counts[${username}]=${admin_membership_count}
done

employee_needed=0
admin_needed=0
for username in "${employee_usernames[@]}"; do
  [[ ${employee_membership_counts[${username}]} == 1 ]] || ((employee_needed += 1))
done
for username in "${admin_usernames[@]}"; do
  [[ ${admin_membership_counts[${username}]} == 1 ]] || ((admin_needed += 1))
done

if [[ ${mode} == --apply ]]; then
  for username in "${employee_usernames[@]}"; do
    if [[ ${employee_membership_counts[${username}]} == 0 ]]; then
      curl_admin --request PUT --header 'Content-Type: application/json' \
        --data "${employee_group_representation}" \
        "${issuer}/admin/realms/${realm}/users/${user_ids[${username}]}/groups/${employee_group_id}" >/dev/null
    fi
  done
  for username in "${admin_usernames[@]}"; do
    if [[ ${admin_membership_counts[${username}]} == 0 ]]; then
      curl_admin --request PUT --header 'Content-Type: application/json' \
        --data "${admin_group_representation}" \
        "${issuer}/admin/realms/${realm}/users/${user_ids[${username}]}/groups/${admin_group_id}" >/dev/null
    fi
  done
fi

for username in "${employee_usernames[@]}"; do
  user_groups=$(curl_admin "${issuer}/admin/realms/${realm}/users/${user_ids[${username}]}/groups?first=0&max=100&briefRepresentation=true")
  [[ $(jq --arg id "${employee_group_id}" '[.[] | select(.id == $id)] | length' <<<"${user_groups}") == 1 ]] || {
    echo "${username}: 적용 뒤 /${employee_group_name} membership 검증에 실패했다." >&2
    exit 1
  }
done
for username in "${admin_usernames[@]}"; do
  user_groups=$(curl_admin "${issuer}/admin/realms/${realm}/users/${user_ids[${username}]}/groups?first=0&max=100&briefRepresentation=true")
  [[ $(jq --arg id "${admin_group_id}" '[.[] | select(.id == $id)] | length' <<<"${user_groups}") == 1 ]] || {
    echo "${username}: 적용 뒤 /${admin_group_name} membership 검증에 실패했다." >&2
    exit 1
  }
done

echo "AWS-HR-03-FIX-01 Keycloak=PASS employee_users=${#employee_usernames[@]}/${#employee_usernames[@]} admin_users=${#admin_usernames[@]}/${#admin_usernames[@]} employee_add_needed=${employee_needed} admin_add_needed=${admin_needed}"
