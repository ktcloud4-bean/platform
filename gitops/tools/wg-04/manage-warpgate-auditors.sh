#!/usr/bin/env bash
# WG-04: Warpgate audit-reader에 필요한 Keycloak group 한 건과 특권 사용자 한 명의
# membership만 수렴시킨다. master recovery ID의 credential 원문·token은 출력하지 않는다.
set -Eeuo pipefail

mode=${1:-}
[[ ${mode} == --check || ${mode} == --apply ]] || {
  echo '사용법: gitops/tools/wg-04/manage-warpgate-auditors.sh --check|--apply' >&2
  exit 2
}

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
readonly repo_root
readonly secret_root=${KTC_SECRET_ROOT:-/home/imcherry/secrets/ktcloud4-bean}
readonly keycloak_secret_dir=${KC01_SECRET_DIR:-${secret_root}/keycloak}
readonly issuer=https://sso.imcherry5778.xyz
readonly issuer_host=sso.imcherry5778.xyz
readonly connect_ip=${KC01_CONNECT_IP:-10.10.20.10}
readonly realm=platform
readonly group_name=warpgate-auditors
readonly username=imcherry5778-admin
readonly recovery_username=imcherry-kc-recovery

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
temp_dir=$(mktemp -d)
readonly temp_dir
cleanup() {
  find "${temp_dir}" -type f -delete
  rmdir "${temp_dir}"
}
trap cleanup EXIT INT TERM

readonly admin_header=${temp_dir}/keycloak-admin.header
python3 "${repo_root}/gitops/tools/kc-01/browser-login.py" \
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

group_query="${issuer}/admin/realms/${realm}/groups?search=${group_name}&exact=true&briefRepresentation=false"
groups=$(curl_admin "${group_query}" | jq --arg name "${group_name}" \
  '[.[] | select(.name == $name and .path == ("/" + $name))]')
case $(jq 'length' <<<"${groups}") in
  0)
    if [[ ${mode} == --apply ]]; then
      curl_admin --request POST --header 'Content-Type: application/json' \
        --data '{"name":"warpgate-auditors"}' \
        "${issuer}/admin/realms/${realm}/groups" >/dev/null
      groups=$(curl_admin "${group_query}" | jq --arg name "${group_name}" \
        '[.[] | select(.name == $name and .path == ("/" + $name))]')
    fi
    ;;
  1) ;;
  *)
    echo '/warpgate-auditors group이 중복되어 변경하지 않는다.' >&2
    exit 1
    ;;
esac

[[ $(jq 'length' <<<"${groups}") == 1 ]] || {
  echo 'WG-04 Keycloak=PENDING group=/warpgate-auditors' >&2
  exit 3
}
group_id=$(jq -r '.[0].id' <<<"${groups}")
readonly group_id

users=$(curl_admin "${issuer}/admin/realms/${realm}/users?username=${username}&exact=true" \
  | jq --arg username "${username}" \
    '[.[] | select(.username == $username)]')
[[ $(jq 'length' <<<"${users}") == 1 ]] || {
  echo 'imcherry5778-admin이 platform realm에 정확히 한 건이어야 한다.' >&2
  exit 1
}
[[ $(jq -r '.[0].enabled' <<<"${users}") == true ]] || {
  echo 'imcherry5778-admin이 disabled 상태여서 변경하지 않는다.' >&2
  exit 1
}
user_id=$(jq -r '.[0].id' <<<"${users}")
readonly user_id

# master realm recovery ID가 platform realm에서 이 일상 감사 group을 받는 실수를
# 감지만 한다. recovery 경계는 이 도구가 자동으로 삭제하거나 고치지 않는다.
recovery_users=$(curl_admin "${issuer}/admin/realms/${realm}/users?username=${recovery_username}&exact=true" \
  | jq --arg username "${recovery_username}" '[.[] | select(.username == $username)]')
case $(jq 'length' <<<"${recovery_users}") in
  0) ;;
  1)
    recovery_id=$(jq -r '.[0].id' <<<"${recovery_users}")
    recovery_memberships=$(curl_admin "${issuer}/admin/realms/${realm}/users/${recovery_id}/groups?max=100")
    if jq -e --arg group_id "${group_id}" '[.[] | select(.id == $group_id)] | length == 1' \
      <<<"${recovery_memberships}" >/dev/null; then
      echo 'imcherry-kc-recovery는 /warpgate-auditors member가 될 수 없다. 변경하지 않는다.' >&2
      exit 1
    fi
    ;;
  *)
    echo 'platform realm의 imcherry-kc-recovery가 중복되어 변경하지 않는다.' >&2
    exit 1
    ;;
esac

memberships=$(curl_admin "${issuer}/admin/realms/${realm}/users/${user_id}/groups?max=100")
if ! jq -e --arg group_id "${group_id}" '[.[] | select(.id == $group_id)] | length == 1' <<<"${memberships}" >/dev/null; then
  if [[ ${mode} == --apply ]]; then
    curl_admin --request PUT \
      "${issuer}/admin/realms/${realm}/users/${user_id}/groups/${group_id}" >/dev/null
  else
    echo 'WG-04 Keycloak=PENDING member=imcherry5778-admin group=/warpgate-auditors' >&2
    exit 3
  fi
fi

memberships=$(curl_admin "${issuer}/admin/realms/${realm}/users/${user_id}/groups?max=100")
jq -e --arg group_id "${group_id}" '[.[] | select(.id == $group_id)] | length == 1' <<<"${memberships}" >/dev/null || {
  echo 'WG-04 group membership did not converge.' >&2
  exit 1
}

echo 'WG-04 Keycloak=PASS group=/warpgate-auditors member=imcherry5778-admin recovery=unchanged'
