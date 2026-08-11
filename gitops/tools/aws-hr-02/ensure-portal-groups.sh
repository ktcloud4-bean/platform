#!/usr/bin/env bash
# AWS-HR-02: Dashy/Pomerium가 공통으로 소비하는 top-level HR group을 수렴시킨다.
set -Eeuo pipefail

mode=${1:-}
[[ ${mode} == --check || ${mode} == --apply ]] || {
  echo '사용법: gitops/tools/aws-hr-02/ensure-portal-groups.sh --check|--apply' >&2
  exit 2
}

readonly secret_root=${KTC_SECRET_ROOT:-/home/imcherry/secrets/ktcloud4-bean}
readonly keycloak_secret_dir=${KC01_SECRET_DIR:-${secret_root}/keycloak}
readonly issuer=https://sso.imcherry5778.xyz
readonly issuer_host=sso.imcherry5778.xyz
readonly connect_ip=${KC01_CONNECT_IP:-10.10.20.10}
readonly realm=platform
readonly group_names=(hr-users hr-admins)

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

for group_name in "${group_names[@]}"; do
  groups=$(curl_admin "${issuer}/admin/realms/${realm}/groups?search=${group_name}&exact=true&briefRepresentation=false" \
    | jq --arg name "${group_name}" '[.[] | select(.name == $name and .path == ("/" + $name))]')
  case $(jq 'length' <<<"${groups}") in
    0)
      if [[ ${mode} == --apply ]]; then
        curl_admin --request POST --header 'Content-Type: application/json' \
          --data "{\"name\":\"${group_name}\"}" \
          "${issuer}/admin/realms/${realm}/groups" >/dev/null
        groups=$(curl_admin "${issuer}/admin/realms/${realm}/groups?search=${group_name}&exact=true&briefRepresentation=false" \
          | jq --arg name "${group_name}" '[.[] | select(.name == $name and .path == ("/" + $name))]')
      else
        echo "AWS-HR-02 check: /${group_name} group 생성 필요"
      fi
      ;;
    1) ;;
    *)
      echo "/${group_name} group이 중복되어 변경하지 않는다." >&2
      exit 1
      ;;
  esac
  [[ $(jq 'length' <<<"${groups}") == 1 ]] || {
    echo "/${group_name} group 생성 후 정확히 한 건으로 수렴하지 않았다." >&2
    exit 1
  }
done

echo 'AWS-HR-02 Keycloak=PASS groups=/hr-users,/hr-admins'
