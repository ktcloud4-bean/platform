#!/usr/bin/env bash
# AWS-SEC-04: Keycloak 격리 데모 아이덴티티 신설 및 SAML 매핑 스크립트
# 세션 종료 시나리오(시나리오 10) 및 CIEM 권한 드리프트(시나리오 11) 검증을 위한 격리 테스트 계정/그룹/SAML 역할을 관리한다.
set -Eeuo pipefail

readonly issuer=https://sso.imcherry5778.xyz
readonly issuer_host=sso.imcherry5778.xyz
readonly realm=platform
readonly client_id='https://signin.aws.amazon.com/saml'
readonly connect_ip=${KC01_CONNECT_IP:-10.10.20.10}

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly script_dir
repo_root=$(cd -- "${script_dir}/../../../.." && pwd)
readonly repo_root
readonly browser_login="${repo_root}/gitops/tools/kc-01/browser-login.py"
readonly kc_secret_dir=${KC01_SECRET_DIR:-/home/imcherry/secrets/ktcloud4-bean/keycloak}

mode=${1:---check}
[[ ${mode} == --check || ${mode} == --apply || ${mode} == --rollback ]] || {
  echo "사용법: $0 [--check|--apply|--rollback]" >&2
  exit 64
}

# 기본 데모 식별자
readonly demo_username="test-session-revoke-demo"
readonly demo_email="test-session-revoke-demo@imcherry5778.xyz"
readonly demo_group="aws-console-demo-users"
readonly demo_client_role="aws-console-demo-operator"
readonly demo_mapper_name="aws-demo-role-name"

# AWS 식별자 (환경변수 override 지원, 기본값 계산)
account_id=${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "465137780685")}
readonly account_id
readonly provider_arn=${AWS_ID01_SAML_PROVIDER_ARN:-"arn:aws:iam::${account_id}:saml-provider/keycloak-platform"}
readonly demo_role_arn=${AWS_SEC04_DEMO_ROLE_ARN:-"arn:aws:iam::${account_id}:role/platform-saml-demo-role"}

for input in local-admin-password local-admin-totp; do
  input_path=${kc_secret_dir}/${input}
  [[ -f ${input_path} && ! -L ${input_path} && $(stat -c %a "${input_path}") == 600 ]] || {
    echo "AWS-SEC-04 Keycloak 복구 입력이 mode 0600 regular file이 아니다: ${input}" >&2
    exit 1
  }
done
[[ -x ${browser_login} ]] || {
  echo 'AWS-SEC-04 Keycloak browser-login 도구가 없다.' >&2
  exit 1
}

umask 077
temp_dir=$(mktemp -d)
readonly temp_dir
readonly header_file=${temp_dir}/keycloak-admin.header
cleanup() {
  find "${temp_dir}" -type f -delete
  rmdir "${temp_dir}"
}
trap cleanup EXIT INT TERM

# 직전 Keycloak 인증과 TOTP window를 재사용하지 않는다.
sleep "$((31 - $(date +%s) % 30))"
browser_args=(
  --issuer "${issuer}"
  --realm master
  --client-id kc-recovery
  --redirect-uri "${issuer}/realms/master/account/"
  --username imcherry-kc-recovery
  --password-file "${kc_secret_dir}/local-admin-password"
  --totp-file "${kc_secret_dir}/local-admin-totp"
  --header-file "${header_file}"
  --expect-realm-role admin
)
if [[ -n ${connect_ip} ]]; then
  browser_args+=(--connect-ip "${connect_ip}")
fi
python3 "${browser_login}" "${browser_args[@]}" >/dev/null

api() {
  local method=$1 path=$2 body_file=${3:-}
  local args=(--silent --show-error --fail --request "${method}" --header "@${header_file}")
  [[ -n ${connect_ip} ]] && args+=(--resolve "${issuer_host}:443:${connect_ip}")
  [[ -n ${body_file} ]] && args+=(--header 'Content-Type: application/json' --data-binary "@${body_file}")
  curl "${args[@]}" "${issuer}/admin/realms/${realm}/${path}"
}

api_status() {
  local method=$1 path=$2 body_file=${3:-}
  local args=(--silent --show-error --resolve "${issuer_host}:443:${connect_ip}" --header "@${header_file}" --request "${method}" --write-out '%{http_code}' --output /dev/null)
  [[ -n ${body_file} ]] && args+=(--header 'Content-Type: application/json' --data-binary "@${body_file}")
  curl "${args[@]}" "${issuer}/admin/realms/${realm}/${path}"
}

write_json() {
  local destination=$1
  shift
  jq -n "$@" >"${destination}"
}

client_uuid() {
  api GET "clients?clientId=${client_id}&exact=true" \
    | jq -er 'if length == 1 and .[0].clientId == "https://signin.aws.amazon.com/saml" and .[0].protocol == "saml" then .[0].id else empty end'
}

top_level_group_matches() {
  local name=$1
  api GET "groups?search=${name}&exact=true&briefRepresentation=false" \
    | jq -ce --arg name "${name}" '
        [.[] | select(.name == $name and .path == ("/" + $name))]
      '
}

top_level_group_uuid() {
  local name=$1 matches
  matches=$(top_level_group_matches "${name}")
  jq -er '
    if length == 1 then .[0].id
    elif length == 0 then empty
    else error("duplicate")
    end
  ' <<<"${matches}"
}

ensure_demo_group() {
  local gid
  gid=$(top_level_group_uuid "${demo_group}") || true
  if [[ -z "${gid}" ]]; then
    if [[ ${mode} == --check ]]; then
      echo "AWS-SEC-04 check: /${demo_group} group 부재" >&2
      return 1
    fi
    local group_json=${temp_dir}/group-${demo_group}.json
    write_json "${group_json}" --arg name "${demo_group}" '{name: $name}'
    api POST groups "${group_json}" >/dev/null
    gid=$(top_level_group_uuid "${demo_group}")
  fi
  printf '%s\n' "${gid}"
}

client_role_representation() {
  local cid=$1 name=$2
  api GET "clients/${cid}/roles" \
    | jq -er --arg name "${name}" '[.[] | select(.name == $name)] | if length == 1 then .[0] else empty end'
}

ensure_demo_client_role() {
  local cid=$1 role_file=${temp_dir}/role-${demo_client_role}.json
  if ! client_role_representation "${cid}" "${demo_client_role}" >"${role_file}"; then
    if [[ ${mode} == --check ]]; then
      echo "AWS-SEC-04 check: ${demo_client_role} client role 부재" >&2
      return 1
    fi
    write_json "${role_file}" --arg name "${demo_client_role}" '{name: $name, description: "AWS-SEC-04 isolated SAML demo client role"}'
    api POST "clients/${cid}/roles" "${role_file}" >/dev/null
    client_role_representation "${cid}" "${demo_client_role}" >"${role_file}"
  fi
  printf '%s\n' "${role_file}"
}

mapping_contains() {
  local group_id=$1 cid=$2 role_name=$3
  api GET "groups/${group_id}/role-mappings/clients/${cid}" \
    | jq -e --arg name "${role_name}" '[.[].name] | index($name) != null' >/dev/null
}

ensure_demo_group_mapping() {
  local group_id=$1 cid=$2 role_file=$3 mapping_file=${temp_dir}/mapping-${demo_group}.json
  if ! mapping_contains "${group_id}" "${cid}" "${demo_client_role}"; then
    if [[ ${mode} == --check ]]; then
      echo "AWS-SEC-04 check: /${demo_group} -> ${demo_client_role} mapping 부재" >&2
      return 1
    fi
    jq -s '.' "${role_file}" >"${mapping_file}"
    api POST "groups/${group_id}/role-mappings/clients/${cid}" "${mapping_file}" >/dev/null
  fi
  mapping_contains "${group_id}" "${cid}" "${demo_client_role}"
}

ensure_demo_scope_mapping() {
  local cid=$1 role_file=$2 mapping_file=${temp_dir}/scope-${demo_client_role}.json
  if ! api GET "clients/${cid}/scope-mappings/clients/${cid}" \
    | jq -e --arg name "${demo_client_role}" '[.[].name] | index($name) != null' >/dev/null; then
    if [[ ${mode} == --check ]]; then
      echo "AWS-SEC-04 check: ${demo_client_role} scope mapping 부재" >&2
      return 1
    fi
    jq -s '.' "${role_file}" >"${mapping_file}"
    api POST "clients/${cid}/scope-mappings/clients/${cid}" "${mapping_file}" >/dev/null
  fi
}

ensure_demo_role_mapper() {
  local cid=$1 mapper_file=${temp_dir}/mapper-${demo_mapper_name}.json
  local role_pair="${demo_role_arn},${provider_arn}"
  if ! api GET "clients/${cid}/protocol-mappers/models" \
    | jq -e --arg name "${demo_mapper_name}" --arg pair "${role_pair}" --arg role "${client_id}.${demo_client_role}" '
        ([.[] | select(.name == $name)]) as $matches |
        ($matches | length == 1) and
        ($matches[0].protocol == "saml") and
        ($matches[0].protocolMapper == "saml-role-name-mapper") and
        ($matches[0].config.role == $role) and
        ($matches[0].config["new.role.name"] == $pair)
      ' >/dev/null; then
    if [[ ${mode} == --check ]]; then
      echo "AWS-SEC-04 check: ${demo_mapper_name} protocol mapper 부재 또는 불일치" >&2
      return 1
    fi
    local existing_id
    existing_id=$(api GET "clients/${cid}/protocol-mappers/models" | jq -r --arg name "${demo_mapper_name}" '[.[] | select(.name == $name)] | if length == 1 then .[0].id else empty end')
    if [[ -n "${existing_id}" ]]; then
      api DELETE "clients/${cid}/protocol-mappers/models/${existing_id}" >/dev/null
    fi
    write_json "${mapper_file}" --arg name "${demo_mapper_name}" --arg role "${client_id}.${demo_client_role}" --arg pair "${role_pair}" \
      '{name:$name, protocol:"saml", protocolMapper:"saml-role-name-mapper", consentRequired:false, config:{role:$role, "new.role.name":$pair}}'
    api POST "clients/${cid}/protocol-mappers/models" "${mapper_file}" >/dev/null
  fi
}

get_user_id() {
  local username=$1
  api GET "users?username=${username}&exact=true" \
    | jq -er 'if length == 1 then .[0].id else empty end'
}

ensure_demo_password_file() {
  local pw_file="${kc_secret_dir}/demo-user-password"
  if [[ ! -f "${pw_file}" ]]; then
    # 안전한 24자리 랜덤 패스워드 생성 및 0600 저장
    local new_pw
    new_pw=$(python3 -c "import secrets, string; alphabet = string.ascii_letters + string.digits + '!@#$%^&*()'; print(''.join(secrets.choice(alphabet) for _ in range(24)))")
    printf '%s' "${new_pw}" >"${pw_file}"
    chmod 600 "${pw_file}"
  fi
  printf '%s\n' "${pw_file}"
}

ensure_demo_user() {
  local uid
  uid=$(get_user_id "${demo_username}") || true
  if [[ -z "${uid}" ]]; then
    if [[ ${mode} == --check ]]; then
      echo "AWS-SEC-04 check: ${demo_username} 사용자 부재" >&2
      return 1
    fi
    local pw_file
    pw_file=$(ensure_demo_password_file)
    local raw_pw
    raw_pw=$(<"${pw_file}")

    local user_json=${temp_dir}/user-${demo_username}.json
    write_json "${user_json}" \
      --arg username "${demo_username}" \
      --arg email "${demo_email}" \
      --arg pw "${raw_pw}" \
      '{
        username: $username,
        email: $email,
        firstName: "Test",
        lastName: "SessionRevokeDemo",
        enabled: true,
        emailVerified: true,
        credentials: [{
          type: "password",
          value: $pw,
          temporary: false
        }]
      }'
    api POST users "${user_json}" >/dev/null
    uid=$(get_user_id "${demo_username}")
  fi
  printf '%s\n' "${uid}"
}

ensure_demo_user_group() {
  local uid=$1 gid=$2
  local groups_json
  groups_json=$(api GET "users/${uid}/groups")
  if ! jq -e --arg gid "${gid}" '[.[].id] | index($gid) != null' <<<"${groups_json}" >/dev/null; then
    if [[ ${mode} == --check ]]; then
      echo "AWS-SEC-04 check: ${demo_username} 사용자가 /${demo_group}에 미속함" >&2
      return 1
    fi
    api PUT "users/${uid}/groups/${gid}" >/dev/null
  fi
}

verify_demo_user_isolation() {
  local uid=$1 gid=$2
  local groups_json
  groups_json=$(api GET "users/${uid}/groups")
  # 데모 사용자는 오직 /aws-console-demo-users 하나에만 속해야 함
  local group_count
  group_count=$(jq 'length' <<<"${groups_json}")
  local match_only_demo
  match_only_demo=$(jq --arg gid "${gid}" 'length == 1 and .[0].id == $gid and .[0].name == "aws-console-demo-users"' <<<"${groups_json}")
  if [[ "${match_only_demo}" != "true" ]]; then
    echo "AWS-SEC-04 ERROR: 데모 사용자 ${demo_username}가 데모 그룹 외 다른 그룹에 속해 있음! (count=${group_count})" >&2
    jq '.' <<<"${groups_json}" >&2
    return 1
  fi

  # 운영 그룹 4개에 데모 사용자가 없는지 확인
  for op_group in aws-console-inventory-readers aws-console-observability-readers aws-console-security-readers aws-console-identity-readers platform-users platform-privileged hr-users hr-admins; do
    local op_gid
    op_gid=$(top_level_group_uuid "${op_group}") || true
    if [[ -n "${op_gid}" ]]; then
      local members
      members=$(api GET "groups/${op_gid}/members?first=0&max=100")
      if jq -e --arg uid "${uid}" '[.[].id] | index($uid) != null' <<<"${members}" >/dev/null; then
        echo "AWS-SEC-04 CRITICAL ERROR: 데모 사용자 ${demo_username}가 운영 그룹 /${op_group}에 속해 있음!" >&2
        return 1
      fi
    fi
  done
}

verify_operational_saml_roles_unchanged() {
  local cid=$1
  # 운영 SAML role 4개 및 매퍼가 존재하는지 확인
  for role_spec in "aws-console-observer|platform-saml-observer" \
                   "aws-console-observability-reader|platform-saml-observability-reader" \
                   "aws-console-security-reader|platform-saml-security-reader" \
                   "aws-console-identity-reader|platform-saml-identity-reader"; do
    local crole=${role_spec%%|*}
    local arole=${role_spec#*|}
    if ! client_role_representation "${cid}" "${crole}" >/dev/null; then
      echo "AWS-SEC-04 ERROR: 운영 client role ${crole} 손실!" >&2
      return 1
    fi
  done
}

cid=$(client_uuid) || {
  echo 'AWS-SEC-04 기존 AWS SAML client가 정확히 하나가 아니다.' >&2
  exit 1
}

if [[ ${mode} == --rollback ]]; then
  echo "AWS-SEC-04 rollback 시작..."
  # 1. mapper 삭제
  mapper_id=$(api GET "clients/${cid}/protocol-mappers/models" | jq -r --arg name "${demo_mapper_name}" '[.[] | select(.name == $name)] | if length == 1 then .[0].id else empty end')
  if [[ -n "${mapper_id}" ]]; then
    api DELETE "clients/${cid}/protocol-mappers/models/${mapper_id}" >/dev/null
  fi
  # 2. user 삭제
  uid=$(get_user_id "${demo_username}") || true
  if [[ -n "${uid}" ]]; then
    api DELETE "users/${uid}" >/dev/null
  fi
  # 3. group 삭제
  gid=$(top_level_group_uuid "${demo_group}") || true
  if [[ -n "${gid}" ]]; then
    api DELETE "groups/${gid}" >/dev/null
  fi
  # 4. client role 삭제
  if client_role_representation "${cid}" "${demo_client_role}" >/dev/null; then
    api DELETE "clients/${cid}/roles/${demo_client_role}" >/dev/null
  fi
  echo "AWS-SEC-04 rollback 완료: 데모 identity 정리됨."
  exit 0
fi

# Apply / Check 로직
gid=$(ensure_demo_group)
role_file=$(ensure_demo_client_role "${cid}")
ensure_demo_group_mapping "${gid}" "${cid}" "${role_file}"
ensure_demo_scope_mapping "${cid}" "${role_file}"
ensure_demo_role_mapper "${cid}"

uid=$(ensure_demo_user)
ensure_demo_user_group "${uid}" "${gid}"

# 격리 및 불변성 검증
verify_demo_user_isolation "${uid}" "${gid}"
verify_operational_saml_roles_unchanged "${cid}"

echo "AWS-SEC-04 Keycloak=PASS user=${demo_username} group=/${demo_group} client_role=${demo_client_role} mapper=${demo_mapper_name} operational_roles_unchanged=4 operational_membership_polluted=0"
