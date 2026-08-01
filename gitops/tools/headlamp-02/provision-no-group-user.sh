#!/usr/bin/env bash
# HEADLAMP-02의 Pomerium 무group 거부 검증에만 쓰는 단일 Keycloak identity를 관리한다.
set -Eeuo pipefail

usage() {
  cat <<'EOF'
사용법:
  KC01_SECRET_DIR=<저장소 밖 KC-01 비밀 디렉터리> \
  ./gitops/tools/headlamp-02/provision-no-group-user.sh --check|--apply

--check는 platform realm의 headlamp-no-group user가 없거나 정확히 no-group 검증
identity인지 읽기 전용으로 확인한다. --apply는 user가 없을 때만 외부 mode 0600
password/TOTP 입력을 만들고 user 한 건을 추가한다. Keycloak 기본 CONFIGURE_TOTP action만,
이미 no-group·password+TOTP가 일치하는 이 task 전용 identity에서 제거할 수 있다.
기존 user, group, credential은 보정하지 않는다.
EOF
}

mode=${1:-}
if [[ "${mode}" != --check && "${mode}" != --apply ]]; then
  usage >&2
  exit 2
fi

: "${KC01_SECRET_DIR:?저장소 밖 KC-01 비밀 디렉터리가 필요하다}"
readonly issuer=https://sso.imcherry5778.xyz
readonly issuer_host=sso.imcherry5778.xyz
readonly connect_ip=${KC01_CONNECT_IP:-10.10.20.10}
readonly username=headlamp-no-group
readonly password_file=${KC01_SECRET_DIR}/headlamp-no-group-password
readonly totp_file=${KC01_SECRET_DIR}/headlamp-no-group-totp
repo_root=$(git rev-parse --show-toplevel)
readonly repo_root

case "${KC01_SECRET_DIR}" in
  /|/home|/home/*/projects|/home/*/projects/*|"${repo_root}"|"${repo_root}"/*)
    echo "KC01_SECRET_DIR가 너무 넓거나 저장소 경로다: ${KC01_SECRET_DIR}" >&2
    exit 1
    ;;
esac
[[ "${KC01_SECRET_DIR}" = /* ]] || {
  echo "KC01_SECRET_DIR는 절대 경로여야 한다." >&2
  exit 1
}
for required in local-admin-password local-admin-totp; do
  [[ -s "${KC01_SECRET_DIR}/${required}" ]] || {
    echo "KC-01 복구 입력이 없다: ${required}" >&2
    exit 1
  }
done
python3 - "${connect_ip}" <<'PY'
import ipaddress, sys
assert ipaddress.ip_address(sys.argv[1]).version == 4
PY

umask 077
temp_dir=$(mktemp -d)
readonly temp_dir
cleanup() {
  rm -rf "${temp_dir}"
}
trap cleanup EXIT INT TERM

admin_header=${temp_dir}/admin.header
users_json=${temp_dir}/users.json
groups_json=${temp_dir}/groups.json
credentials_json=${temp_dir}/credentials.json
payload_json=${temp_dir}/user.json
response_json=${temp_dir}/response.json

# 직전 Keycloak 인증 흐름과 TOTP code를 공유하지 않는다.
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
  --header-file "${admin_header}" \
  --connect-ip "${connect_ip}" \
  --expect-realm-role admin >/dev/null

curl_admin() {
  curl --silent --show-error --fail \
    --resolve "${issuer_host}:443:${connect_ip}" \
    --header "@${admin_header}" \
    "$@"
}

read_user() {
  curl_admin "${issuer}/admin/realms/platform/users?username=${username}&exact=true" >"${users_json}"
}

assert_existing_user_matches() {
  local user_id
  user_id=$(jq -r '.[0].id' "${users_json}")
  [[ "${user_id}" =~ ^[0-9a-f-]{36}$ ]] || return 1
  curl_admin "${issuer}/admin/realms/platform/users/${user_id}/groups" >"${groups_json}"
  curl_admin "${issuer}/admin/realms/platform/users/${user_id}/credentials" >"${credentials_json}"
  jq -e '
    length == 1 and
    .[0].username == "headlamp-no-group" and
    .[0].enabled == true and
    ((.[0].requiredActions // []) == [])
  ' "${users_json}" >/dev/null &&
    jq -e 'length == 0' "${groups_json}" >/dev/null &&
    jq -e '([.[].type] | sort) == ["otp", "password"]' "${credentials_json}" >/dev/null
}

safe_user_summary() {
  jq '[.[] | {username, enabled, requiredActions: (.requiredActions // [])}]' "${users_json}"
  jq '[.[] | {path}]' "${groups_json}"
  jq '[.[] | {type, userLabel}]' "${credentials_json}"
}

only_default_configure_totp_action() {
  jq -e '
    length == 1 and
    .[0].username == "headlamp-no-group" and
    .[0].enabled == true and
    ((.[0].requiredActions // []) == ["CONFIGURE_TOTP"])
  ' "${users_json}" >/dev/null &&
    jq -e 'length == 0' "${groups_json}" >/dev/null &&
    jq -e '([.[].type] | sort) == ["otp", "password"]' "${credentials_json}" >/dev/null
}

clear_default_configure_totp_action() {
  local user_id
  user_id=$(jq -r '.[0].id' "${users_json}")
  [[ "${user_id}" =~ ^[0-9a-f-]{36}$ ]] || return 1
  jq -n --arg username "${username}" '{username: $username, enabled: true, requiredActions: []}' >"${payload_json}"
  local http_status
  http_status=$(curl --silent --show-error \
    --resolve "${issuer_host}:443:${connect_ip}" \
    --output "${response_json}" --write-out '%{http_code}' \
    --request PUT \
    --header "@${admin_header}" \
    --header 'Content-Type: application/json' \
    --data-binary "@${payload_json}" \
    "${issuer}/admin/realms/platform/users/${user_id}")
  [[ "${http_status}" == 204 ]] || return 1
  read_user
  assert_existing_user_matches
}

read_user
user_count=$(jq 'length' "${users_json}")
case "${user_count}" in
  0)
    echo "HEADLAMP-02 Keycloak 차이: ${username} user 0건 -> 무group 검증 identity 생성 대상"
    ;;
  1)
    if assert_existing_user_matches; then
      echo "HEADLAMP-02 Keycloak 차이: ${username} user 1건 -> enabled, no-group, password+TOTP 일치"
    elif [[ "${mode}" == --apply ]] && only_default_configure_totp_action && clear_default_configure_totp_action; then
      echo "HEADLAMP-02: task 전용 ${username}의 기본 CONFIGURE_TOTP action만 제거했다."
    else
      safe_user_summary
      echo "live ${username} user가 HEADLAMP-02 no-group 검증 계약과 다르다. 보정하지 않는다." >&2
      exit 1
    fi
    ;;
  *)
    echo "username=${username} live 객체가 ${user_count}건이다. 변경하지 않는다." >&2
    exit 1
    ;;
esac

if [[ "${mode}" == --check ]]; then
  exit 0
fi

if [[ "${user_count}" -eq 1 ]]; then
  [[ -f "${password_file}" && ! -L "${password_file}" && -s "${password_file}" ]] &&
    [[ -f "${totp_file}" && ! -L "${totp_file}" && -s "${totp_file}" ]] || {
      echo "기존 ${username} user의 외부 password/TOTP 입력이 없다. 생성하거나 덮어쓰지 않는다." >&2
      exit 1
    }
  [[ "$(stat -c %a "${password_file}")" == 600 && "$(stat -c %a "${totp_file}")" == 600 ]] || {
      echo "기존 ${username} user의 외부 password/TOTP 입력은 mode 0600이어야 한다." >&2
      exit 1
    }
  exit 0
fi

[[ -d "${KC01_SECRET_DIR}" && ! -L "${KC01_SECRET_DIR}" ]] || {
  echo "KC01_SECRET_DIR가 regular directory가 아니다." >&2
  exit 1
}
generate_password() {
  local candidate
  while true; do
    candidate=$(openssl rand -base64 48 | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-40)
    if [[ ${#candidate} -eq 40 && "${candidate}" =~ [A-Z] && "${candidate}" =~ [a-z] && "${candidate}" =~ [0-9] ]]; then
      printf '%s\n' "${candidate}"
      return
    fi
  done
}

generate_totp() {
  openssl rand 20 | base32 | tr -d '=\n'
  printf '\n'
}

if [[ ! -e "${password_file}" && ! -e "${totp_file}" ]]; then
  generate_password >"${password_file}"
  generate_totp >"${totp_file}"
elif [[ -f "${password_file}" && ! -L "${password_file}" && -s "${password_file}" &&
        -f "${totp_file}" && ! -L "${totp_file}" && -s "${totp_file}" &&
        "$(stat -c %a "${password_file}")" == 600 && "$(stat -c %a "${totp_file}")" == 600 ]]; then
  echo "${username} user가 없고 기존 task 소유 mode 0600 입력이 있어 덮어쓰지 않고 재사용한다."
else
  echo "${username} user가 없는데 no-group 비밀 파일 상태가 불완전하다. 덮어쓰지 않는다." >&2
  exit 1
fi
chmod 0600 "${password_file}" "${totp_file}"
[[ -s "${password_file}" && -s "${totp_file}" ]] || {
  echo "무group 검증 비밀 파일 생성에 실패했다." >&2
  exit 1
}

jq -n \
  --rawfile password "${password_file}" \
  --rawfile totp "${totp_file}" \
  '{
    username: "headlamp-no-group",
    enabled: true,
    requiredActions: [],
    credentials: [
      {type: "password", value: ($password | rtrimstr("\n")), temporary: false},
      {
        type: "otp",
        userLabel: "HEADLAMP-02 no-group TOTP",
        secretData: ({value: ($totp | rtrimstr("\n"))} | tojson),
        credentialData: ({subType: "totp", digits: 6, counter: 0, period: 30, algorithm: "HmacSHA256", secretEncoding: "BASE32"} | tojson)
      }
    ]
  }' >"${payload_json}"

http_status=$(curl --silent --show-error \
  --resolve "${issuer_host}:443:${connect_ip}" \
  --output "${response_json}" --write-out '%{http_code}' \
  --request POST \
  --header "@${admin_header}" \
  --header 'Content-Type: application/json' \
  --data-binary "@${payload_json}" \
  "${issuer}/admin/realms/platform/users")
[[ "${http_status}" == 201 ]] || {
  echo "${username} user 생성 실패: HTTP ${http_status}" >&2
  exit 1
}

read_user
if ! assert_existing_user_matches; then
  if only_default_configure_totp_action && clear_default_configure_totp_action; then
    echo "HEADLAMP-02: 새 ${username}의 기본 CONFIGURE_TOTP action만 제거했다."
  else
    safe_user_summary
    echo "생성 후 ${username} no-group 검증 계약에 실패했다." >&2
    exit 1
  fi
fi
echo "HEADLAMP-02: ${username} no-group 검증 identity와 외부 mode 0600 입력을 생성했다."
